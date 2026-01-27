import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

const String kDeviceName = 'FOC-CTRL';

// 입력(표시 RPM) * 10 = 실제 RPM -> rad/s 전송
const double kCmdRpmScale = 10.0;
const double kRpmToRad = 2.0 * math.pi / 60.0; // RPM -> rad/s

// quick buttons (표시 RPM 기준)
const double kBtnRpm1 = 33.3333333;
const double kBtnRpm2 = 45.0;

// NUS UUIDs
final Guid kNusService = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
final Guid kNusRxChar  = Guid("6E400002-B5A3-F393-E0A9-E50E24DCCA9E"); // write
final Guid kNusTxChar  = Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E"); // notify

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
      debugShowCheckedModeBanner: false));
}

class FocBlePage extends StatefulWidget {
  const FocBlePage({super.key});
  @override
  State<FocBlePage> createState() => _FocBlePageState();
}

class _FocBlePageState extends State<FocBlePage> with WidgetsBindingObserver {
  // BLE
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _tx;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  Timer? _autoScanTimer;

  bool _scanning = false;
  bool _foundTarget = false;
  int? _lastRssi;
  DateTime? _lastSeen;

  bool get _connected => _device != null && _device!.isConnected;

  // telemetry (ESP32가 이미 1/10 처리된 "표시 RPM"을 보내므로 그대로 표시)
  String _lastLine = '';
  int _lastMillis = 0;
  double _rpmDisp = 0.0; // ✅ 수신값 그대로 표시용 RPM
  DateTime? _lastTelemTime;

  // line buffer for notify
  final StringBuffer _notifyBuf = StringBuffer();

  // presets (표시 RPM 값 저장/전송)
  late TextEditingController _p1;
  late TextEditingController _p2;
  SharedPreferences? _prefs;

  bool get _reachableNow {
    if (!_foundTarget || _lastSeen == null) return false;
    return DateTime.now().difference(_lastSeen!).inSeconds <= 10;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 기본값(표시 RPM 기준)
    _p1 = TextEditingController(text: kBtnRpm1.toStringAsFixed(7));
    _p2 = TextEditingController(text: kBtnRpm2.toStringAsFixed(1));

    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _p1.text = _prefs?.getString('preset1') ?? _p1.text;
    _p2.text = _prefs?.getString('preset2') ?? _p2.text;
    setState(() {});

    await _ensurePermissions();

    if (!Platform.isIOS) {
      await FlutterBluePlus.turnOn();
    }

    // ✅ 자동 스캔: 미연결 & 미발견이면 계속 찾음 (찾으면 멈춤)
    _autoScanTimer?.cancel();
    _autoScanTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      if (_connected) return;
      if (_foundTarget) return;
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
      _foundTarget = false;
      _lastRssi = null;
      _lastSeen = null;
    }

    setState(() => _scanning = true);

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) async {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;

        if (name == kDeviceName) {
          _foundTarget = true;
          _lastRssi = r.rssi;
          _lastSeen = DateTime.now();
          _device = r.device;

          if (mounted) setState(() {});

          // ✅ 찾으면 즉시 검색 중지
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
      await _device!.connect(
        license: License.free,
        autoConnect: false,
      );
      await _discoverAndSubscribe();
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
    _rx = null;
    _tx = null;
  }

  Future<void> _discoverAndSubscribe() async {
    final services = await _device!.discoverServices();

    BluetoothService? nus;
    for (final s in services) {
      if (s.uuid == kNusService) {
        nus = s;
        break;
      }
    }
    if (nus == null) throw Exception("NUS service not found");

    for (final c in nus.characteristics) {
      if (c.uuid == kNusRxChar) _rx = c;
      if (c.uuid == kNusTxChar) _tx = c;
    }
    if (_rx == null || _tx == null) throw Exception("NUS characteristics not found");

    await _tx!.setNotifyValue(true);
    _notifySub?.cancel();
    _notifySub = _tx!.onValueReceived.listen((data) {
      final s = utf8.decode(data, allowMalformed: true);
      _notifyBuf.write(s);

      final bufStr = _notifyBuf.toString();
      final parts = bufStr.split('\n');
      if (parts.length <= 1) return;

      _notifyBuf
        ..clear()
        ..write(parts.last);

      for (int i = 0; i < parts.length - 1; i++) {
        final line = parts[i].trim();
        if (line.isEmpty) continue;
        _handleTelemetryLine(line);
      }
    });
  }

  void _handleTelemetryLine(String line) {
    _lastLine = line;

    int millis = _lastMillis;
    double rpmDisp = _rpmDisp;

    final tokens = line.split(',');
    if (tokens.length >= 2) {
      millis = int.tryParse(tokens[0].trim()) ?? millis;
      rpmDisp = double.tryParse(tokens[1].trim()) ?? rpmDisp;
    } else {
      rpmDisp = double.tryParse(line.trim()) ?? rpmDisp;
    }

    _lastMillis = millis;

    // ✅ ESP32가 이미 1/10 처리된 표시 RPM을 보냄 -> 그대로 표시
    _rpmDisp = rpmDisp;

    _lastTelemTime = DateTime.now();
    if (mounted) setState(() {});
  }

  // ✅ 입력은 "표시 RPM" -> 실제 RPM = 입력*10 -> rad/s 변환 후 전송
  Future<void> _sendDisplayRpm(String displayRpmText) async {
    if (_rx == null) return;

    final dispRpm = double.tryParse(displayRpmText.trim());
    if (dispRpm == null) return;

    final actualRpm = dispRpm * kCmdRpmScale;  // ✅ 10배
    final radPerSec = actualRpm * kRpmToRad;

    final payload = utf8.encode("${radPerSec.toStringAsFixed(6)}\n");
    await _rx!.write(payload, withoutResponse: true);
  }

  Future<void> _savePresets() async {
    await _prefs?.setString('preset1', _p1.text.trim());
    await _prefs?.setString('preset2', _p2.text.trim());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _autoScanTimer?.cancel();
    _scanSub?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // 스캔 중이면 먼저 멈추고
      unawaited(_stopScan());
      // 연결되어 있으면 끊기
      unawaited(_disconnect());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("GMT Turntable Controller"),
        actions: [
          IconButton(
            onPressed: _scanning ? _stopScan : () => _startScan(resetFound: true, timeoutSec: 6),
            icon: Icon(_scanning ? Icons.stop : Icons.search),
            tooltip: _scanning ? "스캔 중지" : "스캔",
          ),
        ],
      ),

      // ✅ 하단 고정 버튼 3개 (같은 크기)
      bottomNavigationBar: SafeArea(
        top: false, // 위쪽은 보호할 필요 없음
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _connected ? () async {
                      await _sendDisplayRpm(kBtnRpm1.toString());
                    } : null,
                    child: Text("${kBtnRpm1.toStringAsFixed(7)} RPM"),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _connected ? () async {
                      await _sendDisplayRpm(kBtnRpm2.toString());
                    } : null,
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
                    onPressed: _connected ? () async {
                      await _sendDisplayRpm("0");
                    } : null,
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusCard(),
            const SizedBox(height: 12),
            _telemetryCard(),
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
            Text("장비 발견: ${_foundTarget ? "YES" : "NO"}"
                "${_lastRssi != null ? "  (RSSI $_lastRssi dBm)" : ""}"),
            Text("연결 가능(최근 10초): ${_reachableNow ? "YES" : "NO"}"),
            if (_lastSeen != null) Text("마지막 발견: ${_lastSeen!.toLocal()}"),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text("연결 상태: ${_connected ? "CONNECTED" : "DISCONNECTED"}")),
                ElevatedButton(
                  onPressed: (_device != null && !_connected) ? () async {
                    try { await _connect(); } catch (_) {}
                  } : null,
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ✅ 수신 RPM 그대로 표시 (이미 1/10 처리됨)
            Text("RPM: ${_rpmDisp.toStringAsFixed(4)}",
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text("millis: $_lastMillis"),
            Text("last: ${_lastTelemTime?.toLocal() ?? "-"}"),
            const SizedBox(height: 6),
            Text("raw line: $_lastLine", maxLines: 2, overflow: TextOverflow.ellipsis),
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
            const Text("속도 지령 2개"),
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
                  onPressed: _connected ? () async {
                    await _savePresets();
                    await _sendDisplayRpm(_p1.text);
                  } : null,
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
                  onPressed: _connected ? () async {
                    await _savePresets();
                    await _sendDisplayRpm(_p2.text);
                  } : null,
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
}
