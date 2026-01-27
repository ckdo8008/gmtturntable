import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

const String kDeviceName = 'FOC-CTRL';
const double kRpmToRad = 2.0 * math.pi / 60.0; // RPM -> rad/s

// NUS UUIDs
final Guid kNusService = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
final Guid kNusRxChar  = Guid("6E400002-B5A3-F393-E0A9-E50E24DCCA9E"); // write
final Guid kNusTxChar  = Guid("6E400003-B5A3-F393-E0A9-E50E24DCCA9E"); // notify

void main() {
  FlutterBluePlus.setLogLevel(LogLevel.info, color: false);
  runApp(const MaterialApp(home: FocBlePage(), debugShowCheckedModeBanner: false));
}

class FocBlePage extends StatefulWidget {
  const FocBlePage({super.key});
  @override
  State<FocBlePage> createState() => _FocBlePageState();
}

class _FocBlePageState extends State<FocBlePage> {
  // BLE
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _tx;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  bool _scanning = false;
  bool _foundTarget = false;
  int? _lastRssi;
  DateTime? _lastSeen;

  // telemetry
  String _lastLine = '';
  int _lastMillis = 0;
  double _lastRpm = 0.0;
  DateTime? _lastTelemTime;

  // line buffer for notify
  final StringBuffer _notifyBuf = StringBuffer();

  // presets (rad/s)
  late TextEditingController _p1;
  late TextEditingController _p2;
  SharedPreferences? _prefs;

  bool get _connected => _device != null && (_device!.isConnected);

  @override
  void initState() {
    super.initState();
    _p1 = TextEditingController(text: "34.906585");
    _p2 = TextEditingController(text: "0.000000");
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _p1.text = _prefs?.getString('preset1') ?? _p1.text;
    _p2.text = _prefs?.getString('preset2') ?? _p2.text;
    setState(() {});

    await _ensurePermissions();

    // Android에서 BT 켜기 시도(가능한 경우)
    if (!Platform.isIOS) {
      await FlutterBluePlus.turnOn();
    }
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;

    // Android 12+ 권한: bluetoothScan / bluetoothConnect
    // Android 11 이하 스캔은 위치 권한이 필요할 수 있어서 locationWhenInUse도 같이 요청
    final req = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];

    final result = await req.request();
    final denied = result.entries.where((e) => !e.value.isGranted).toList();
    if (denied.isNotEmpty) {
      // 최소한 동작은 하되, 스캔/연결이 막힐 수 있음
      // (UI에서 안내만)
    }
  }

  Future<void> _startScan() async {
    if (_scanning) return;

    _foundTarget = false;
    _lastRssi = null;
    _lastSeen = null;

    setState(() => _scanning = true);

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;

        if (name == kDeviceName) {
          _foundTarget = true;
          _lastRssi = r.rssi;
          _lastSeen = DateTime.now();
          _device = r.device; // 타겟 디바이스로 지정
          setState(() {});
          break;
        }
      }
    }, onError: (_) {});

    try {
      await FlutterBluePlus.startScan(
        withNames: [kDeviceName],
        timeout: const Duration(seconds: 6),
      );
      await FlutterBluePlus.isScanning.where((v) => v == false).first;
    } finally {
      _scanning = false;
      setState(() {});
    }
  }

  Future<void> _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    _scanning = false;
    setState(() {});
  }

  Future<void> _connect() async {
    if (_device == null) return;

    await _stopScan();

    // 연결 상태 구독
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
      await _discoverAndSubscribe();
    } catch (e) {
      // 실패 시 정리
      await _cleanupGatt();
      rethrow;
    }
    setState(() {});
  }

  Future<void> _disconnect() async {
    if (_device == null) return;
    try {
      await _device!.disconnect();
    } catch (_) {}
    await _cleanupGatt();
    setState(() {});
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
    if (nus == null) {
      throw Exception("NUS service not found");
    }

    for (final c in nus.characteristics) {
      if (c.uuid == kNusRxChar) _rx = c;
      if (c.uuid == kNusTxChar) _tx = c;
    }
    if (_rx == null || _tx == null) {
      throw Exception("NUS characteristics not found");
    }

    // Notify 구독
    await _tx!.setNotifyValue(true);
    _notifySub?.cancel();
    _notifySub = _tx!.onValueReceived.listen((data) {
      final s = utf8.decode(data, allowMalformed: true);
      _notifyBuf.write(s);

      // '\n' 단위로 라인 처리
      final bufStr = _notifyBuf.toString();
      final parts = bufStr.split('\n');
      if (parts.length <= 1) return;

      // 마지막 조각은 미완성일 수 있으니 남기고, 이전 라인만 처리
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
    // ESP32가 "millis, rpm" 형식으로 보내는 걸 가정
    // 혹시 "rpm"만 오더라도 동작하도록 방어
    _lastLine = line;

    int millis = _lastMillis;
    double rpm = _lastRpm;

    final tokens = line.split(',');
    if (tokens.length >= 2) {
      millis = int.tryParse(tokens[0].trim()) ?? millis;
      rpm = double.tryParse(tokens[1].trim()) ?? rpm;
    } else {
      rpm = double.tryParse(line.trim()) ?? rpm;
    }

    _lastMillis = millis;
    _lastRpm = rpm;
    _lastTelemTime = DateTime.now();

    if (mounted) setState(() {});
  }

  // Future<void> _sendVelocity(String text) async {
  //   if (_rx == null) return;
  //
  //   final v = double.tryParse(text.trim());
  //   if (v == null) return;
  //
  //   // ESP32 쪽 파서가 '\n' 기준이므로 개행 포함
  //   final payload = utf8.encode("${v.toStringAsFixed(6)}\n");
  //
  //   // NUS RX는 보통 writeWithoutResponse를 지원
  //   await _rx!.write(payload, withoutResponse: true);
  // }
  Future<void> _sendRpm(String rpmText) async {
    if (_rx == null) return;

    final rpm = double.tryParse(rpmText.trim());
    if (rpm == null) return;

    final radPerSec = rpm * kRpmToRad; // ✅ 자동 변환

    // ESP32 파서가 '\n' 기준이므로 개행 포함
    final payload = utf8.encode("${radPerSec.toStringAsFixed(6)}\n");
    await _rx!.write(payload, withoutResponse: true);
  }


  Future<void> _savePresets() async {
    await _prefs?.setString('preset1', _p1.text.trim());
    await _prefs?.setString('preset2', _p2.text.trim());
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _notifySub?.cancel();
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connState = _device?.connectionState;

    return Scaffold(
      appBar: AppBar(
        title: const Text("FOC BLE Monitor"),
        actions: [
          IconButton(
            onPressed: _scanning ? _stopScan : _startScan,
            icon: Icon(_scanning ? Icons.stop : Icons.search),
            tooltip: _scanning ? "스캔 중지" : "스캔",
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusCard(connState),
            const SizedBox(height: 12),
            _telemetryCard(),
            const SizedBox(height: 12),
            _controlCard(),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(Stream<BluetoothConnectionState>? connState) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("장비 발견: ${_foundTarget ? "YES" : "NO"}"
                "${_lastRssi != null ? "  (RSSI $_lastRssi dBm)" : ""}"),
            if (_lastSeen != null)
              Text("마지막 발견: ${_lastSeen!.toLocal()}"),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text("연결 상태: ${_connected ? "CONNECTED" : "DISCONNECTED"}"),
                ),
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
            Text("RPM: ${_lastRpm.toStringAsFixed(3)}",
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text("millis: $_lastMillis"),
            Text("last: ${_lastTelemTime?.toLocal() ?? "-"}"),
            const SizedBox(height: 6),
            Text("raw: $_lastLine", maxLines: 2, overflow: TextOverflow.ellipsis),
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
            const Text("속도 지령 (RPM) 2개 저장/전송"),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _p1,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: "Preset #1 (RPM)"),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connected ? () async {
                    await _savePresets();
                    // await _sendVelocity(_p1.text);
                    _sendRpm(_p1.text);
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
                    decoration: const InputDecoration(labelText: "Preset #2 (RPM)"),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connected ? () async {
                    await _savePresets();
                    // await _sendVelocity(_p2.text);
                    await _sendRpm(_p2.text);
                  } : null,
                  child: const Text("전송2"),
                ),
              ],
            ),

            const SizedBox(height: 12),

            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _connected ? () async {
                    // 정지: 0 rad/s 전송 (요구사항: 0rpm 전달)
                    // ESP32는 rad/s를 받으니 0.0 전송
                    // await _sendVelocity("0.0");
                    await _sendRpm("0");
                  } : null,
                  icon: const Icon(Icons.stop),
                  label: const Text("정지(0)"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                ),
                const SizedBox(width: 8),
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
              ],
            ),
          ],
        ),
      ),
    );
  }
}
