import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ================== Device / BLE ==================
const String kDeviceName = 'FOC_TURNTABLE';

final Guid kSvc    = Guid("c0de0001-1d7a-4b2a-9d2f-000000000001");
final Guid kTarget = Guid("c0de0002-1d7a-4b2a-9d2f-000000000001"); // float rad/s (RW)
final Guid kVelPid = Guid("c0de0003-1d7a-4b2a-9d2f-000000000001"); // float[3] (RW)
final Guid kCurPi  = Guid("c0de0004-1d7a-4b2a-9d2f-000000000001"); // float[2] (RW)
final Guid kTelem  = Guid("c0de0005-1d7a-4b2a-9d2f-000000000001"); // notify Telemetry

// ================== App constants ==================
// 표시 RPM -> 실제 RPM = *10 -> rad/s
const double kCmdRpmScale = 10.0;
const double kRpmToRad = 2.0 * math.pi / 60.0;

// quick buttons (표시 RPM)
const double kBtnRpm1 = 33.3333333;
const double kBtnRpm2 = 45.0;

// UI/metrics update throttles (반응성 핵심)
const Duration kUiTick = Duration(milliseconds: 50);      // 20 FPS
const Duration kMetricTick = Duration(milliseconds: 250); // 4 Hz

// Plot window
const double kPlotSeconds = 20.0;
const int kPlotMaxPoints = 1200;

// W&F window
const double kWfWindowSec = 20.0;

// stop condition
const double kStopEpsRpm = 1e-6;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final license1 = await rootBundle.loadString('google_fonts/Nanum_Gothic/OFL.txt');
    final license2 = await rootBundle.loadString('google_fonts/Nanum_Gothic_Coding/OFL.txt');
    yield LicenseEntryWithLineBreaks(['google_fonts'], license1);
    yield LicenseEntryWithLineBreaks(['google_fonts'], license2);
  });
  GoogleFonts.config.allowRuntimeFetching = false;

  FlutterBluePlus.setLogLevel(LogLevel.info, color: false);

  runApp(MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.blue,
      textTheme: GoogleFonts.nanumGothicTextTheme(),
    ),
    home: const FocBlePage(),
    debugShowCheckedModeBanner: false,
  ));
}

// ===============================
// Binary helpers (LE)
// ===============================
Uint8List _f32le(double v) {
  final bd = ByteData(4)..setFloat32(0, v.toDouble(), Endian.little);
  return bd.buffer.asUint8List();
}

double _readF32le(Uint8List b, int off) =>
    ByteData.sublistView(b, off, off + 4).getFloat32(0, Endian.little);

int _readU32le(Uint8List b, int off) =>
    ByteData.sublistView(b, off, off + 4).getUint32(0, Endian.little);

Uint8List _packF32List(List<double> v) {
  final bd = ByteData(4 * v.length);
  for (int i = 0; i < v.length; i++) {
    bd.setFloat32(i * 4, v[i].toDouble(), Endian.little);
  }
  return bd.buffer.asUint8List();
}

// ===============================
// Plot + Model
// ===============================
class _PlotPoint {
  final double t; // seconds
  final double v;
  _PlotPoint(this.t, this.v);
}

class _TelemetryModel extends ChangeNotifier {
  // Latest telemetry
  double rpmDisp = 0.0; // already /10 adjusted in firmware
  double errRad = 0.0;
  int loopUs = 0;
  DateTime? lastTelemTime;

  // Target (display RPM)
  double targetDispRpm = 0.0;

  // PID/PI
  double? velP, velI, velD;
  double? curP, curI;

  // computed metrics
  double? wrmsPct;
  double? wow2sigmaPct;
  double? fsHz;
  String metricNote = '';

  // plot buffers
  final List<_PlotPoint> plotRpm = [];
  final List<_PlotPoint> plotDevW = [];

  // repaint notifier for plot only
  final ValueNotifier<int> plotRepaint = ValueNotifier<int>(0);

  // throttling flags
  bool _dirtyUi = false;
  bool _dirtyMetric = false;

  // wf meter
  final WowFlutterMeter wf = WowFlutterMeter(windowSec: kWfWindowSec);

  // fs estimator
  DateTime? _lastSampleTime;

  void ingestTelemetry(Uint8List payload) {
    // payload: float rpm, float err, uint32 loop_us  (12 bytes)
    if (payload.length < 12) return;

    final now = DateTime.now();

    rpmDisp = _readF32le(payload, 0);
    errRad = _readF32le(payload, 4);
    loopUs = _readU32le(payload, 8);
    lastTelemTime = now;

    // fs estimate (cheap)
    fsHz = _updateFs(now);

    // push plot
    _pushPlot(now, rpmDisp);

    // push wf sample (only store; actual compute on metric tick)
    if (targetDispRpm.abs() > kStopEpsRpm) {
      final devPct = 100.0 * (rpmDisp - targetDispRpm) / targetDispRpm;
      wf.pushSampleOnly(devPct);
      _dirtyMetric = true;
    } else {
      wf.reset();
      wrmsPct = null;
      wow2sigmaPct = null;
      metricNote = '';
    }

    _dirtyUi = true;
  }

  void setVelPid(double p, double i, double d) {
    velP = p; velI = i; velD = d;
    _dirtyUi = true;
  }

  void setCurPi(double p, double i) {
    curP = p; curI = i;
    _dirtyUi = true;
  }

  double? _updateFs(DateTime now) {
    if (_lastSampleTime == null) {
      _lastSampleTime = now;
      return fsHz;
    }
    final dt = now.difference(_lastSampleTime!).inMicroseconds / 1e6;
    _lastSampleTime = now;
    if (dt <= 0) return fsHz;

    final inst = 1.0 / dt;
    fsHz = (fsHz == null) ? inst : (fsHz! * 0.9 + inst * 0.1);
    wf.updateFs(fsHz!);
    return fsHz;
  }

  void _pushPlot(DateTime now, double rpm) {
    final t = now.millisecondsSinceEpoch / 1000.0;
    plotRpm.add(_PlotPoint(t, rpm));
    plotDevW.add(_PlotPoint(t, wf.lastWeightedDevPct));

    if (plotRpm.length > kPlotMaxPoints) {
      plotRpm.removeRange(0, plotRpm.length - kPlotMaxPoints);
    }
    if (plotDevW.length > kPlotMaxPoints) {
      plotDevW.removeRange(0, plotDevW.length - kPlotMaxPoints);
    }

    final cutoff = t - kPlotSeconds;
    while (plotRpm.isNotEmpty && plotRpm.first.t < cutoff) plotRpm.removeAt(0);
    while (plotDevW.isNotEmpty && plotDevW.first.t < cutoff) plotDevW.removeAt(0);

    plotRepaint.value++;
  }

  // called by UI timer
  void flushUiIfDirty() {
    if (!_dirtyUi) return;
    _dirtyUi = false;
    notifyListeners();
  }

  // called by metric timer
  void computeMetricsIfDirty() {
    if (!_dirtyMetric) return;
    _dirtyMetric = false;

    if (targetDispRpm.abs() <= kStopEpsRpm) {
      wrmsPct = null;
      wow2sigmaPct = null;
      metricNote = '';
      return;
    }

    final r = wf.computeNow();
    if (r == null) {
      wrmsPct = null;
      wow2sigmaPct = null;
      metricNote = '샘플 부족';
      _dirtyUi = true;
      return;
    }

    wrmsPct = r.wrmsPct;
    wow2sigmaPct = r.twoSigmaPct;

    final fs = fsHz ?? 0.0;
    if (fs < 20.0) {
      metricNote = '경고: fs=${fs.toStringAsFixed(1)}Hz (표준 W&F 불리)';
    } else {
      metricNote = 'fs=${fs.toStringAsFixed(1)}Hz';
    }

    _dirtyUi = true;
  }
}

// ===============================
// Wow/Flutter Meter (표준형 통계 + 가중 근사)
// ===============================
class WowFlutterMeter {
  WowFlutterMeter({required this.windowSec});
  final double windowSec;

  // raw dev% buffer
  final List<_WfPoint> _buf = [];

  // last weighted dev for plot
  double lastWeightedDevPct = 0.0;

  // filter state
  final _Biquad _bp = _Biquad();
  final _Biquad _lp = _Biquad();
  bool _ready = false;

  double? _fs;

  void updateFs(double fs) {
    _fs = fs;
    _recalc();
  }

  void _recalc() {
    if (_fs == null || _fs! <= 0) return;
    final fs = _fs!;
    final f0 = math.min(4.0, fs * 0.45); // 4Hz center (근사)
    final fLp = math.min(200.0, fs * 0.45);

    _bp.setBandpass(fs: fs, f0: f0, q: 1.0);
    _lp.setLowpass(fs: fs, f0: fLp, q: 0.707);
    _ready = true;
  }

  void reset() {
    _buf.clear();
    lastWeightedDevPct = 0.0;
    _bp.reset();
    _lp.reset();
  }

  void pushSampleOnly(double devPctRaw) {
    final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
    _buf.add(_WfPoint(nowSec, devPctRaw));
    final cutoff = nowSec - windowSec;
    while (_buf.isNotEmpty && _buf.first.tSec < cutoff) {
      _buf.removeAt(0);
    }

    // update lastWeighted for plot quickly
    if (_buf.length >= 2) {
      final mean = _mean();
      final x = devPctRaw - mean;
      double y = x;
      if (_ready) {
        y = _bp.process(y);
        y = _lp.process(y);
      }
      lastWeightedDevPct = y;
    }
  }

  _WfResult? computeNow() {
    if (_buf.length < 50) return null;

    // ----- UNWEIGHTED (다른 앱과 스케일 맞추기 좋음) -----
    final mean = _mean();
    double sumSq = 0.0;
    double sum = 0.0;
    double sum2 = 0.0;

    for (final p in _buf) {
      final x = p.y - mean;      // dev% mean 제거
      sumSq += x * x;
      sum += x;
      sum2 += x * x;
    }

    final n = _buf.length.toDouble();
    final rms = math.sqrt(sumSq / n);

    // stddev = sqrt(E[x^2] - E[x]^2)
    final ex = sum / n;
    final ex2 = sum2 / n;
    final std = math.sqrt(math.max(0.0, ex2 - ex * ex));
    final twoSigma = 2.0 * std;

    // ----- WEIGHTED (현재 근사 필터) -----
    final bp = _Biquad.cloneOf(_bp);
    final lp = _Biquad.cloneOf(_lp);

    double wSumSq = 0.0;
    double wSum = 0.0;
    double wSum2 = 0.0;

    for (final p in _buf) {
      final x0 = p.y - mean;
      double y = x0;
      if (_ready) {
        y = bp.process(y);
        y = lp.process(y);
      }
      wSumSq += y * y;
      wSum += y;
      wSum2 += y * y;
    }

    final wRms = math.sqrt(wSumSq / n);
    final wEx = wSum / n;
    final wEx2 = wSum2 / n;
    final wStd = math.sqrt(math.max(0.0, wEx2 - wEx * wEx));
    final wTwoSigma = 2.0 * wStd;

    return _WfResult(
      wrmsPct: rms,
      twoSigmaPct: twoSigma,
      wWrmsPct: wRms,
      wTwoSigmaPct: wTwoSigma,
    );
  }


  double _mean() {
    double s = 0.0;
    for (final p in _buf) s += p.y;
    return s / _buf.length;
  }
}

class _WfPoint {
  final double tSec;
  final double y;
  _WfPoint(this.tSec, this.y);
}

class _WfResult {
  final double wrmsPct;      // (표시용: UNWEIGHTED)
  final double twoSigmaPct;  // (표시용: UNWEIGHTED)
  final double wWrmsPct;     // (참고용: WEIGHTED)
  final double wTwoSigmaPct; // (참고용: WEIGHTED)
  _WfResult({
    required this.wrmsPct,
    required this.twoSigmaPct,
    required this.wWrmsPct,
    required this.wTwoSigmaPct,
  });
}

// RBJ biquad
class _Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
  double z1 = 0, z2 = 0;

  _Biquad();

  _Biquad.cloneOf(_Biquad other) {
    b0 = other.b0; b1 = other.b1; b2 = other.b2;
    a0 = other.a0; a1 = other.a1; a2 = other.a2;
    z1 = 0; z2 = 0;
  }

  void reset() { z1 = 0; z2 = 0; }

  double process(double x) {
    final y = (b0 / a0) * x + z1;
    z1 = (b1 / a0) * x - (a1 / a0) * y + z2;
    z2 = (b2 / a0) * x - (a2 / a0) * y;
    return y;
  }

  void setLowpass({required double fs, required double f0, required double q}) {
    final w0 = 2.0 * math.pi * f0 / fs;
    final cosw0 = math.cos(w0);
    final sinw0 = math.sin(w0);
    final alpha = sinw0 / (2.0 * q);

    b0 = (1.0 - cosw0) / 2.0;
    b1 = 1.0 - cosw0;
    b2 = (1.0 - cosw0) / 2.0;
    a0 = 1.0 + alpha;
    a1 = -2.0 * cosw0;
    a2 = 1.0 - alpha;
    reset();
  }

  void setBandpass({required double fs, required double f0, required double q}) {
    final w0 = 2.0 * math.pi * f0 / fs;
    final cosw0 = math.cos(w0);
    final sinw0 = math.sin(w0);
    final alpha = sinw0 / (2.0 * q);

    b0 = sinw0 / 2.0;
    b1 = 0.0;
    b2 = -sinw0 / 2.0;
    a0 = 1.0 + alpha;
    a1 = -2.0 * cosw0;
    a2 = 1.0 - alpha;
    reset();
  }
}

// ===============================
// UI Page
// ===============================
class FocBlePage extends StatefulWidget {
  const FocBlePage({super.key});
  @override
  State<FocBlePage> createState() => _FocBlePageState();
}

class _FocBlePageState extends State<FocBlePage> with WidgetsBindingObserver {
  // BLE
  BluetoothDevice? _device;
  BluetoothCharacteristic? _chTarget;
  BluetoothCharacteristic? _chVelPid;
  BluetoothCharacteristic? _chCurPi;
  BluetoothCharacteristic? _chTelem;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  Timer? _autoScanTimer;
  Timer? _uiTimer;
  Timer? _metricTimer;

  bool _scanning = false;
  bool _found = false;
  int? _lastRssi;
  DateTime? _lastSeen;

  bool get _connected => _device != null && _device!.isConnected;
  bool get _reachableNow => _found && _lastSeen != null && DateTime.now().difference(_lastSeen!).inSeconds <= 10;

  // prefs
  SharedPreferences? _prefs;

  // controllers
  late TextEditingController _p1;
  late TextEditingController _p2;

  final _velP = TextEditingController();
  final _velI = TextEditingController();
  final _velD = TextEditingController();
  final _curP = TextEditingController();
  final _curI = TextEditingController();

  bool _pidBusy = false;

  // model
  final _TelemetryModel m = _TelemetryModel();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _p1 = TextEditingController(text: kBtnRpm1.toStringAsFixed(7));
    _p2 = TextEditingController(text: kBtnRpm2.toStringAsFixed(1));
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();

    _p1.text = _prefs?.getString('preset1') ?? _p1.text;
    _p2.text = _prefs?.getString('preset2') ?? _p2.text;

    _velP.text = _prefs?.getString('velP') ?? '';
    _velI.text = _prefs?.getString('velI') ?? '';
    _velD.text = _prefs?.getString('velD') ?? '';
    _curP.text = _prefs?.getString('curP') ?? '';
    _curI.text = _prefs?.getString('curI') ?? '';

    setState(() {});

    await _ensurePermissions();
    if (!Platform.isIOS) {
      await FlutterBluePlus.turnOn();
    }

    // UI tick: only place where setState is triggered
    m.addListener(() {
      if (mounted) setState(() {});
    });

    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(kUiTick, (_) {
      m.flushUiIfDirty();
    });

    _metricTimer?.cancel();
    _metricTimer = Timer.periodic(kMetricTick, (_) {
      m.computeMetricsIfDirty();
      m.flushUiIfDirty();
    });

    // Auto scan
    _autoScanTimer?.cancel();
    _autoScanTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      if (_connected) return;
      if (_found) return;
      if (_scanning) return;
      await _startScan(resetFound: false, timeoutSec: 4);
    });
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;
    final req = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];
    await req.request();
  }

  Future<void> _startScan({bool resetFound = true, int timeoutSec = 6}) async {
    if (_scanning) return;

    if (resetFound) {
      _found = false;
      _lastRssi = null;
      _lastSeen = null;
      _device = null;
    }
    setState(() => _scanning = true);

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) async {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;

        if (name == kDeviceName) {
          _found = true;
          _lastRssi = r.rssi;
          _lastSeen = DateTime.now();
          _device = r.device;

          if (mounted) setState(() {});
          try { await FlutterBluePlus.stopScan(); } catch (_) {}
          break;
        }
      }
    }, onError: (_) {});

    try {
      await FlutterBluePlus.startScan(
        withNames: [kDeviceName],
        timeout: Duration(seconds: timeoutSec),
      );
      await FlutterBluePlus.isScanning.where((v) => v == false).first;
    } finally {
      _scanning = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _stopScan() async {
    try { await FlutterBluePlus.stopScan(); } catch (_) {}
    _scanning = false;
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    if (_device == null) return;
    await _stopScan();

    _connSub?.cancel();
    _connSub = _device!.connectionState.listen((state) async {
      if (!mounted) return;
      setState(() {});
      if (state == BluetoothConnectionState.disconnected) {
        await _cleanupGatt();
      }
    });

    try {
      await _device!.connect(license: License.free, autoConnect: false);
      await _discover();

      // subscribe telemetry
      await _chTelem!.setNotifyValue(true);
      _notifySub?.cancel();
      _notifySub = _chTelem!.onValueReceived.listen((data) {
        // IMPORTANT: no setState here
        m.ingestTelemetry(Uint8List.fromList(data));
      });

      // auto read PID/PI
      unawaited(_autoReadPid());
    } catch (_) {
      await _cleanupGatt();
      rethrow;
    }

    if (mounted) setState(() {});
  }

  Future<void> _disconnect() async {
    if (_device == null) return;
    try { await _device!.disconnect(); } catch (_) {}
    await _cleanupGatt();
    if (mounted) setState(() {});
  }

  Future<void> _cleanupGatt() async {
    _notifySub?.cancel();
    _notifySub = null;

    _chTarget = null;
    _chVelPid = null;
    _chCurPi = null;
    _chTelem = null;
  }

  Future<void> _discover() async {
    final services = await _device!.discoverServices();
    BluetoothService? svc;
    for (final s in services) {
      if (s.uuid == kSvc) { svc = s; break; }
    }
    if (svc == null) throw Exception("Service not found: $kSvc");

    for (final c in svc.characteristics) {
      if (c.uuid == kTarget) _chTarget = c;
      if (c.uuid == kVelPid) _chVelPid = c;
      if (c.uuid == kCurPi) _chCurPi = c;
      if (c.uuid == kTelem) _chTelem = c;
    }
    if (_chTarget == null || _chVelPid == null || _chCurPi == null || _chTelem == null) {
      throw Exception("Characteristics missing");
    }
  }

  // ---------- GATT R/W ----------
  Future<void> _writeTargetRad(double radPerSec) async {
    if (_chTarget == null) return;
    await _chTarget!.write(_f32le(radPerSec), withoutResponse: false);
  }

  Future<void> _writeVelPid(double p, double i, double d) async {
    if (_chVelPid == null) return;
    await _chVelPid!.write(_packF32List([p, i, d]), withoutResponse: false);
  }

  Future<void> _writeCurPi(double p, double i) async {
    if (_chCurPi == null) return;
    await _chCurPi!.write(_packF32List([p, i]), withoutResponse: false);
  }

  Future<(double,double,double)?> _readVelPid() async {
    if (_chVelPid == null) return null;
    final v = await _chVelPid!.read();
    final b = Uint8List.fromList(v);
    if (b.length < 12) return null;
    return (_readF32le(b,0), _readF32le(b,4), _readF32le(b,8));
  }

  Future<(double,double)?> _readCurPi() async {
    if (_chCurPi == null) return null;
    final v = await _chCurPi!.read();
    final b = Uint8List.fromList(v);
    if (b.length < 8) return null;
    return (_readF32le(b,0), _readF32le(b,4));
  }

  // ---------- UI actions ----------
  Future<void> _sendDisplayRpm(String dispText) async {
    final disp = double.tryParse(dispText.trim());
    if (disp == null) return;

    m.targetDispRpm = disp;

    final actualRpm = disp * kCmdRpmScale;
    final rad = actualRpm * kRpmToRad;
    await _writeTargetRad(rad);

    // stop이면 meter reset
    if (disp.abs() <= kStopEpsRpm) {
      m.wf.reset();
      m.wrmsPct = null;
      m.wow2sigmaPct = null;
      m.metricNote = '';
    }
  }

  Future<void> _autoReadPid() async {
    if (!_connected || _pidBusy) return;
    _pidBusy = true;
    if (mounted) setState(() {});

    try {
      final vp = await _readVelPid();
      if (vp != null) {
        m.setVelPid(vp.$1, vp.$2, vp.$3);

        // 타이핑 중 덮어쓰기 방지: 필드 비어있을 때만 채움
        if (_velP.text.isEmpty) _velP.text = vp.$1.toStringAsFixed(6);
        if (_velI.text.isEmpty) _velI.text = vp.$2.toStringAsFixed(6);
        if (_velD.text.isEmpty) _velD.text = vp.$3.toStringAsFixed(6);
      }

      final cp = await _readCurPi();
      if (cp != null) {
        m.setCurPi(cp.$1, cp.$2);
        if (_curP.text.isEmpty) _curP.text = cp.$1.toStringAsFixed(6);
        if (_curI.text.isEmpty) _curI.text = cp.$2.toStringAsFixed(6);
      }
    } finally {
      _pidBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _applyVelPid() async {
    final p = double.tryParse(_velP.text.trim());
    final i = double.tryParse(_velI.text.trim());
    final d = double.tryParse(_velD.text.trim());
    if (p == null || i == null || d == null) return;

    await _prefs?.setString('velP', _velP.text.trim());
    await _prefs?.setString('velI', _velI.text.trim());
    await _prefs?.setString('velD', _velD.text.trim());

    await _writeVelPid(p, i, d);

    // readback
    final vp = await _readVelPid();
    if (vp != null) m.setVelPid(vp.$1, vp.$2, vp.$3);
  }

  Future<void> _applyCurPi() async {
    final p = double.tryParse(_curP.text.trim());
    final i = double.tryParse(_curI.text.trim());
    if (p == null || i == null) return;

    await _prefs?.setString('curP', _curP.text.trim());
    await _prefs?.setString('curI', _curI.text.trim());

    await _writeCurPi(p, i);

    final cp = await _readCurPi();
    if (cp != null) m.setCurPi(cp.$1, cp.$2);
  }

  Future<void> _savePresets() async {
    await _prefs?.setString('preset1', _p1.text.trim());
    await _prefs?.setString('preset2', _p2.text.trim());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _autoScanTimer?.cancel();
    _uiTimer?.cancel();
    _metricTimer?.cancel();

    _scanSub?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();

    _p1.dispose();
    _p2.dispose();

    _velP.dispose();
    _velI.dispose();
    _velD.dispose();
    _curP.dispose();
    _curI.dispose();

    m.plotRepaint.dispose();
    m.dispose();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_stopScan());
      unawaited(_disconnect());
    }
  }

  // ================= UI =================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("FOC Turntable BLE"),
        actions: [
          IconButton(
            onPressed: _scanning ? _stopScan : () => _startScan(resetFound: true, timeoutSec: 6),
            icon: Icon(_scanning ? Icons.stop : Icons.search),
            tooltip: _scanning ? "스캔 중지" : "스캔",
          ),
        ],
      ),

      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _connected ? () => _sendDisplayRpm(kBtnRpm1.toString()) : null,
                    child: Text("${kBtnRpm1.toStringAsFixed(7)} RPM"),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _connected ? () => _sendDisplayRpm(kBtnRpm2.toString()) : null,
                    child: Text("${kBtnRpm2.toStringAsFixed(0)} RPM"),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: _connected ? () => _sendDisplayRpm("0") : null,
                    child: const Text("정지"),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),

      body: Padding(
        padding: const EdgeInsets.all(14),
        child: ListView(
          children: [
            _statusCard(),
            const SizedBox(height: 12),
            _telemetryCard(),
            const SizedBox(height: 12),
            _plotCard(),
            const SizedBox(height: 12),
            _pidCard(),
            const SizedBox(height: 12),
            _controlCard(),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("장비 발견: ${_found ? "YES" : "NO"}"
                "${_lastRssi != null ? "  (RSSI $_lastRssi dBm)" : ""}"),
            Text("연결 가능(최근 10초): ${_reachableNow ? "YES" : "NO"}"),
            if (_lastSeen != null) Text("마지막 발견: ${_lastSeen!.toLocal()}"),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text("연결 상태: ${_connected ? "CONNECTED" : "DISCONNECTED"}")),
                ElevatedButton(
                  onPressed: (_device != null && !_connected)
                      ? () async { try { await _connect(); } catch (_) {} }
                      : null,
                  child: const Text("연결"),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _connected ? _disconnect : null,
                  child: const Text("끊기"),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "대상 디바이스: ${_device == null ? "(미지정)" : _device!.platformName}  "
                  "${_device == null ? "" : _device!.remoteId.str}",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _telemetryCard() {
    final hasWf = (m.targetDispRpm.abs() > kStopEpsRpm) && (m.wrmsPct != null) && (m.wow2sigmaPct != null);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("RPM: ${m.rpmDisp.toStringAsFixed(4)}",
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text("Target RPM: ${m.targetDispRpm.toStringAsFixed(4)}"),
            Text("ERR(rad/s): ${m.errRad.toStringAsFixed(4)}   loop(us): ${m.loopUs}"),
            Text("fs(est): ${m.fsHz == null ? "-" : m.fsHz!.toStringAsFixed(1)} Hz   ${m.metricNote}"),

            // const SizedBox(height: 10),
            // Text("WRMS: ${hasWf ? "${m.wrmsPct!.toStringAsFixed(4)} %" : "--"}",
            //     style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            // Text("Wow 2σ: ${hasWf ? "${m.wow2sigmaPct!.toStringAsFixed(4)} %" : "--"}",
            //     style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _plotCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Plot (RPM / weighted dev%)"),
            const SizedBox(height: 10),
            RepaintBoundary(
              child: SizedBox(
                height: 180,
                width: double.infinity,
                child: CustomPaint(
                  painter: _PlotPainter(
                    repaint: m.plotRepaint,
                    rpm: m.plotRpm,
                    dev: m.plotDevW,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pidCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text("PID / PI 설정")),
                OutlinedButton(
                  onPressed: (_connected && !_pidBusy) ? _autoReadPid : null,
                  child: Text(_pidBusy ? "읽는 중..." : "자동 읽기"),
                ),
              ],
            ),
            const SizedBox(height: 10),

            const Text("Velocity PID (float[3])"),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: _numField(_velP, "P")),
                const SizedBox(width: 8),
                Expanded(child: _numField(_velI, "I")),
                const SizedBox(width: 8),
                Expanded(child: _numField(_velD, "D")),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connected ? _applyVelPid : null,
                  child: const Text("적용"),
                ),
              ],
            ),

            const SizedBox(height: 14),
            const Text("Current PI (float[2])"),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: _numField(_curP, "P")),
                const SizedBox(width: 8),
                Expanded(child: _numField(_curI, "I")),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connected ? _applyCurPi : null,
                  child: const Text("적용"),
                ),
              ],
            ),

            const SizedBox(height: 10),
            Text(
              "VelPID (read): ${m.velP == null ? "-" : "${m.velP!.toStringAsFixed(4)}, ${m.velI!.toStringAsFixed(4)}, ${m.velD!.toStringAsFixed(4)}"}\n"
                  "CurPI  (read): ${m.curP == null ? "-" : "${m.curP!.toStringAsFixed(4)}, ${m.curI!.toStringAsFixed(4)}"}",
              style: const TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("속도 지령 2개 (표시 RPM)"),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _p1,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: "Preset #1 (표시 RPM)"),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connected ? () async { await _savePresets(); await _sendDisplayRpm(_p1.text); } : null,
                  child: const Text("전송1"),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _p2,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: "Preset #2 (표시 RPM)"),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connected ? () async { await _savePresets(); await _sendDisplayRpm(_p2.text); } : null,
                  child: const Text("전송2"),
                ),
              ],
            ),

            const SizedBox(height: 12),

            Row(
              children: [
                OutlinedButton(
                  onPressed: () async {
                    await _savePresets();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Preset 저장 완료")),
                      );
                    }
                  },
                  child: const Text("값 저장"),
                ),
                const SizedBox(width: 12),
                Text("스캔: ${_scanning ? "ON" : "OFF"}"),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numField(TextEditingController c, String label) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
    );
  }
}

// ===============================
// Plot painter (부분 repaint)
// ===============================
class _PlotPainter extends CustomPainter {
  _PlotPainter({
    required Listenable repaint,
    required this.rpm,
    required this.dev,
  }) : super(repaint: repaint);

  final List<_PlotPoint> rpm;
  final List<_PlotPoint> dev;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Colors.transparent;
    canvas.drawRect(Offset.zero & size, bg);

    final border = Paint()
      ..color = const Color(0x22000000)
      ..strokeWidth = 1;

    canvas.drawRect(Offset.zero & size, border);

    if (rpm.length < 2) {
      _drawText(canvas, const Offset(8, 8), "no data");
      return;
    }

    final t0 = rpm.first.t;
    final t1 = rpm.last.t;
    final dt = (t1 - t0).abs() < 1e-6 ? 1.0 : (t1 - t0);

    double rMin = rpm.first.v, rMax = rpm.first.v;
    for (final p in rpm) {
      if (p.v < rMin) rMin = p.v;
      if (p.v > rMax) rMax = p.v;
    }
    final rSpan = (rMax - rMin).abs() < 1e-9 ? 1.0 : (rMax - rMin);

    double dMin = -0.1, dMax = 0.1;
    if (dev.length >= 2) {
      dMin = dev.first.v; dMax = dev.first.v;
      for (final p in dev) {
        if (p.v < dMin) dMin = p.v;
        if (p.v > dMax) dMax = p.v;
      }
      final s = (dMax - dMin).abs();
      if (s < 1e-6) { dMin -= 0.1; dMax += 0.1; }
    }
    final dSpan = (dMax - dMin).abs() < 1e-9 ? 1.0 : (dMax - dMin);

    // grid
    final grid = Paint()
      ..color = const Color(0x11000000)
      ..strokeWidth = 1;
    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5.0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // rpm (blue)
    final pR = Paint()
      ..color = Colors.blue
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final pathR = Path();
    for (int i = 0; i < rpm.length; i++) {
      final x = (rpm[i].t - t0) / dt * size.width;
      final y = size.height - ((rpm[i].v - rMin) / rSpan * size.height);
      if (i == 0) pathR.moveTo(x, y); else pathR.lineTo(x, y);
    }
    canvas.drawPath(pathR, pR);

    // dev (orange)
    if (dev.length >= 2) {
      final pD = Paint()
        ..color = Colors.orange
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;

      final pathD = Path();
      for (int i = 0; i < dev.length; i++) {
        final x = (dev[i].t - t0) / dt * size.width;
        final y = size.height - ((dev[i].v - dMin) / dSpan * size.height);
        if (i == 0) pathD.moveTo(x, y); else pathD.lineTo(x, y);
      }
      canvas.drawPath(pathD, pD);
    }

    _drawText(
      canvas,
      const Offset(8, 8),
      "RPM(blue)  Dev%(w)(orange)\n"
          "rpm:[${rMin.toStringAsFixed(3)}..${rMax.toStringAsFixed(3)}]  "
          "dev:[${dMin.toStringAsFixed(3)}..${dMax.toStringAsFixed(3)}]",
    );
  }

  void _drawText(Canvas canvas, Offset pos, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: 11, color: Colors.black54),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 600);
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant _PlotPainter oldDelegate) => false;
}
