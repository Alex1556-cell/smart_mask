import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'dart:async'; 
import 'dart:convert'; 
import 'package:shared_preferences/shared_preferences.dart'; 
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; 
import 'package:permission_handler/permission_handler.dart'; 
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart'; 
import 'package:vibration/vibration.dart'; 
import 'package:fl_chart/fl_chart.dart'; 

// ============================================================================
// SONILLO HYBRID BLUETOOTH SYSTEM - FLUTTER APP DOKUMENTATION
// ============================================================================
/*
 * ARCHITECTURE: Hybrid A2DP + BLE Client (Flutter)
 * 
 * HANDYS ROLLE IM HYBRID SYSTEM:
 * - Verbindung zur Kontrolle (via BLE)
 * - Audio-Streaming gleichzeitig möglich (A2DP)
 * - Beide Modi arbeiten PARALLEL, nicht sequenziell
 * 
 * BLE KOMMUNIKATION MIT ESP32:
 * UUIDs müssen EXAKT mit ESP32 übereinstimmen!
 * SERVICE_UUID:        "12345678-1234-1234-1234-123456789012"
 * ALARM_CHAR_UUID:     "87654321-4321-4321-4321-210987654321"
 * SETTINGS_CHAR_UUID:  "11111111-2222-3333-4444-555555555555"
 * TIME_SYNC_CHAR_UUID: "99999999-9999-9999-9999-999999999999"
 * 
 * FLOW DER APP:
 * 
 * 1. USER STARTEN APP
 *    ↓
 *    [Onboarding] → [MainNavigationScreen]
 *    ↓
 * 2. USER SUCHT ESP32 IM SCAN-SCREEN
 *    ↓
 *    [BLE Scanner aktiviert] → ["SonilloMask" Gerät gefunden]
 *    ↓
 * 3. USER KLICKT AUF "SonilloMask"
 *    ↓
 *    [connectToESP32()] → BLE-Verbindung aufgebaut
 *    ↓
 * 4. AUTOMATISCH: Zeit & Einstellungen synchronisiert
 *    ↓
 *    [_syncTimeWithESP32()] → ESP32 kennt jetzt aktuelle Uhrzeit
 *    [_sendSettingsToESP32()] → LED-Vorlauf, etc.
 *    [_sendAllAlarmsToESP32()] → Wecker-Zeiten übertragen
 *    ↓
 * 5. TIMER STARTEN: Jede Minute Zeit syncen
 *    ↓
 *    [_startTimeSyncTimer()] → Timer.periodic(Duration(seconds: 60))
 *    ↓
 * 6. USER KANN GLEICHZEITIG MUSIK ABSPIELEN
 *    ↓
 *    BLE bleibt verbunden → A2DP-Sink auf ESP32 verbindet sich
 *    ↓
 *    HYBRID-MODE: Beide arbeiten gleichzeitig!
 * 
 * ⚠️  WICHTIG: MOCK-DATEN ENTFERNT!
 * Alle Demo-Daten sind entfernt. Nur noch echte Funktionen:
 * - Onboarding zeigt echte erste Nutzung
 * - Alarme: Nur selbst erstellte (leer nach dem ersten Start)
 * - Sounds: Nur als UI-Platzhalter (echte Wiedergabe über A2DP)
 * - Stats: Echte Daten aus SharedPreferences (werden von ESP32 gesammelt)
 * 
 * TODO (für zukünftige Versionen):
 * ⚠️  Sleep-Daten: ESP32 sollte Sleep-Tracking speichern und via BLE senden
 * ⚠️  Sound-Streaming: Statt lokalen Sounds Streaming von Server/BLE
 * ⚠️  BLE Notifications: ESP32 sollte App benachrichtigen wenn Alarm ausgelöst wird
 */

// --- GLOBALE VARIABLEN ---
List<Map<String, dynamic>> myAlarms = [];
SharedPreferences? prefs;

// Globale Einstellungen
double globalLightPreStart = 15.0;
bool globalLucidEnabled = false;
bool isFirstLaunch = true;

// Der Echtzeit-Schalter für das Logo
ValueNotifier<bool> isSunriseActive = ValueNotifier(false);
bool isTestingSunrise = false; 

// --- BLE VERBINDUNG ---
BluetoothDevice? connectedDevice;
BluetoothCharacteristic? alarmCharacteristic;
BluetoothCharacteristic? settingsCharacteristic;
BluetoothCharacteristic? timeSyncCharacteristic;

// BLE UUIDs (müssen mit ESP32 übereinstimmen!)
const String SERVICE_UUID = "12345678-1234-1234-1234-123456789012";
const String ALARM_CHAR_UUID = "87654321-4321-4321-4321-210987654321";
const String SETTINGS_CHAR_UUID = "11111111-2222-3333-4444-555555555555";
const String TIME_SYNC_CHAR_UUID = "99999999-9999-9999-9999-999999999999";

ValueNotifier<bool> isConnectedToBLE = ValueNotifier(false);
Timer? timeSyncTimer;
Function(String)? onAlarmTriggered; // Globaler Callback für den Wecker-Dialog

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  _loadData();
  runApp(const SonilloApp());
}

void _loadData() {
  isFirstLaunch = prefs?.getBool('isFirstLaunch') ?? true;
  
  String? alarmsJson = prefs?.getString('alarms');
  if (alarmsJson != null) {
    List<dynamic> decoded = jsonDecode(alarmsJson);
    myAlarms = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
    for (var alarm in myAlarms) {
      if (!alarm.containsKey('lastTriggered')) alarm['lastTriggered'] = '';
    }
  } else {
    // KEINE MOCK-DATEN MEHR - Starte mit leerer Liste!
    myAlarms = [];
  }
  
  globalLightPreStart = prefs?.getDouble('lightPreStart') ?? 15.0;
  globalLucidEnabled = prefs?.getBool('lucidEnabled') ?? false;
}

void saveAlarms() { 
  prefs?.setString('alarms', jsonEncode(myAlarms));
  // Sende Alarme zum ESP32
  _sendAllAlarmsToESP32();
}

void saveSettings() {
  prefs?.setDouble('lightPreStart', globalLightPreStart);
  prefs?.setBool('lucidEnabled', globalLucidEnabled);
  // Sende Settings zum ESP32
  _sendSettingsToESP32();
}

void completeOnboarding() {
  prefs?.setBool('isFirstLaunch', false);
}

// === BLE FUNKTIONEN ===

/// Sende alle aktiven Alarme zum ESP32
Future<void> _sendAllAlarmsToESP32() async {
  if (alarmCharacteristic == null || !isConnectedToBLE.value) {
    print("[BLE] ⚠️ Nicht verbunden - Alarme können nicht gesendet werden");
    return;
  }

  // Alle aktiven Alarme in einer Liste bündeln
  List<Map<String, dynamic>> alarmsList = [];
  for (var alarm in myAlarms) {
    if (alarm['isActive'] == true) {
      alarmsList.add({
        'time': alarm['time'],
        'label': alarm['label'],
        'enabled': alarm['isActive']
      });
    }
  }

  try {
    String jsonData = jsonEncode(alarmsList);
    
    List<int> bytes = utf8.encode(jsonData);
    await alarmCharacteristic!.write(bytes, withoutResponse: false);
    
    print("[BLE] ✓ Alarme gesendet: $jsonData");
  } catch (e) {
    print("[BLE] ❌ Fehler beim Senden der Alarme: $e");
  }
}

/// Sende Settings (Licht-Vorlauf) zum ESP32
Future<void> _sendSettingsToESP32() async {
  if (settingsCharacteristic == null || !isConnectedToBLE.value) {
    print("[BLE] ⚠️ Nicht verbunden - Settings können nicht gesendet werden");
    return;
  }

  try {
    Map<String, dynamic> settingsData = {
      'prestart': globalLightPreStart.toInt(),
      'lucid': globalLucidEnabled
    };
    String jsonData = jsonEncode(settingsData);
    
    List<int> bytes = utf8.encode(jsonData);
    await settingsCharacteristic!.write(bytes, withoutResponse: false);
    
    print("[BLE] ✓ Settings gesendet: $jsonData");
  } catch (e) {
    print("[BLE] ❌ Fehler beim Senden der Settings: $e");
  }
}

/// Synchronisiere Uhrzeit mit ESP32 (Format: "HH:MM")
Future<void> _syncTimeWithESP32() async {
  if (timeSyncCharacteristic == null || !isConnectedToBLE.value) {
    print("[BLE] ⚠️ Nicht verbunden - Zeit kann nicht synchronisiert werden");
    return;
  }

  try {
    final now = DateTime.now();
    String timeString = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    
    List<int> bytes = utf8.encode(timeString);
    await timeSyncCharacteristic!.write(bytes, withoutResponse: false);
    
    print("[BLE] ✓ Zeit synchronisiert: $timeString");
  } catch (e) {
    print("[BLE] ❌ Fehler beim Synchronisieren der Zeit: $e");
  }
}

/// Starte Timer zur regelmäßigen Zeitsynchronisation (alle 60 Sekunden)
void _startTimeSyncTimer() {
  timeSyncTimer?.cancel();
  
  // Sofort synchronisieren
  _syncTimeWithESP32();
  
  // Dann jede Minute wiederholen
  timeSyncTimer = Timer.periodic(const Duration(seconds: 60), (timer) {
    if (isConnectedToBLE.value) {
      _syncTimeWithESP32();
    } else {
      print("[BLE] Timer läuft aber nicht verbunden - kein Sync");
    }
  });
}

/// Verbinde mit ESP32 via BLE
Future<void> connectToESP32(BluetoothDevice device) async {
  try {
    // FIX 1: 'platformName' statt 'name' verwenden
    print("[BLE] Verbinde zu ${device.platformName}...");

    await device.connect(
      license: License.free,
      autoConnect: false,
    ).timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        // WICHTIG: Nativer Verbindungsabbruch, da das Dart-Timeout allein
        // den Verbindungsaufbau im Hintergrund (OS-Ebene) nicht stoppt!
        device.disconnect();
        throw TimeoutException("BLE Verbindung fehlgeschlagen (Timeout)");
      },
    );

    // Diese Zeilen werden jetzt nur noch erreicht, wenn der connect VOR dem Timeout erfolgreich war
    connectedDevice = device;
    isConnectedToBLE.value = true;

    try {
      await device.requestMtu(512); // MTU hochsetzen für JSON Arrays
      print("[BLE] MTU erfolgreich angehoben");
    } catch (e) {
      print("[BLE] MTU Request fehlgeschlagen: $e");
    }

    print("[BLE] ✓ Verbunden zu ${device.platformName}");
    print("[HYBRID] BLE aktiv - A2DP kann jetzt parallel starten!");

    // Entdecke Services
    List<BluetoothService> services = await device.discoverServices();
    
    for (BluetoothService service in services) {
      if (service.uuid.toString().toLowerCase() == SERVICE_UUID.toLowerCase()) {
        print("[BLE] ✓ Service gefunden!");
        
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          String charUUID = characteristic.uuid.toString().toLowerCase();
          
          if (charUUID == ALARM_CHAR_UUID.toLowerCase()) {
            alarmCharacteristic = characteristic;
            print("[BLE] ✓ Alarm Characteristic gefunden");

            // Auf Alarm-Trigger vom ESP32 horchen
            await alarmCharacteristic!.setNotifyValue(true);
            alarmCharacteristic!.lastValueStream.listen((value) {
              if (value.isNotEmpty) {
                String decoded = utf8.decode(value);
                if (decoded.startsWith("TRIGGER:")) {
                  String label = decoded.substring(8);
                  print("[BLE] 🔔 Wecker-Trigger vom ESP32 empfangen: $label");
                  if (onAlarmTriggered != null) onAlarmTriggered!(label);
                }
              }
            });
          }
          if (charUUID == SETTINGS_CHAR_UUID.toLowerCase()) {
            settingsCharacteristic = characteristic;
            print("[BLE] ✓ Settings Characteristic gefunden");
          }
          if (charUUID == TIME_SYNC_CHAR_UUID.toLowerCase()) {
            timeSyncCharacteristic = characteristic;
            print("[BLE] ✓ Time Sync Characteristic gefunden");
          }
        }
      }
    }

    // Nacheinander synchronisieren (mit Delays)
    await Future.delayed(const Duration(milliseconds: 500));
    await _syncTimeWithESP32();
    await Future.delayed(const Duration(milliseconds: 200));
    await _sendSettingsToESP32();
    await Future.delayed(const Duration(milliseconds: 200));
    await _sendAllAlarmsToESP32();
    
    // Regelmäßige Zeit-Synchronisation starten
    _startTimeSyncTimer();
    
    print("[HYBRID] ✓ Vollständig synchronisiert - bereit für A2DP!");
    
  } catch (e) {
    // Hier landet der Code, wenn es nicht klappt oder das Timeout auslöst
    print("[BLE] ❌ Verbindungsfehler: $e");
    isConnectedToBLE.value = false;
  }
}

/// Trenne Verbindung vom ESP32
Future<void> disconnectFromESP32() async {
  try {
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      print("[BLE] ✓ Verbindung getrennt");
      print("[HYBRID] BLE getrennt - A2DP kann weiterhin aktiv sein!");
    }
    
    connectedDevice = null;
    alarmCharacteristic = null;
    settingsCharacteristic = null;
    timeSyncCharacteristic = null;
    isConnectedToBLE.value = false;
    
    timeSyncTimer?.cancel();
  } catch (e) {
    print("[BLE] ❌ Fehler beim Trennen: $e");
  }
}

// --- DAS SONILLO LOGO ---
class SonilloLogo extends StatelessWidget {
  const SonilloLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: isSunriseActive,
          builder: (context, isActive, child) {
            return Icon(Icons.bedtime, color: isActive ? Colors.orangeAccent : const Color(0xFF6C63FF), size: 28);
          },
        ),
        const SizedBox(width: 8),
        const Text('SONILLO', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2.0, color: Colors.white)),
      ],
    );
  }
}

class SonilloApp extends StatelessWidget {
  const SonilloApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sonillo Premium',
      theme: ThemeData(
        brightness: Brightness.dark, 
        primaryColor: const Color(0xFF6C63FF), 
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, centerTitle: true),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF1A1A1A), 
          selectedItemColor: Color(0xFF6C63FF), 
          unselectedItemColor: Colors.grey
        ),
      ),
      home: isFirstLaunch ? const OnboardingScreen() : const MainNavigationScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- ONBOARDING SCREEN (Kein Mock!) ---
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  void _finishOnboarding() {
    completeOnboarding();
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => const MainNavigationScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          PageView(
            controller: _pageController,
            onPageChanged: (int page) => setState(() => _currentPage = page),
            children: [
              _buildPage(
                icon: Icons.bedtime, 
                color: const Color(0xFF6C63FF),
                title: 'Willkommen bei Sonillo',
                description: 'Verabschiede dich von schrillen Weckern. Erlebe die sanfteste Art, in den Tag zu starten.',
              ),
              _buildPage(
                icon: Icons.bluetooth_connected, 
                color: Colors.blueAccent,
                title: 'Smart & Verbunden',
                description: 'Kopple deine Sonillo Maske über den Radar-Tab, um das volle Potenzial deines Schlafs freizuschalten.',
              ),
              _buildPage(
                icon: Icons.wb_twilight, 
                color: Colors.orangeAccent,
                title: 'Dein persönlicher Sonnenaufgang',
                description: 'Die Maske dimmt das Licht langsam hoch, bevor dein Wecker klingelt. Du wachst erholt auf.',
              ),
            ],
          ),
          
          Positioned(
            bottom: 50, left: 20, right: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: List.generate(3, (index) => AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.only(right: 8),
                    height: 10,
                    width: _currentPage == index ? 25 : 10,
                    decoration: BoxDecoration(
                      color: _currentPage == index ? const Color(0xFF6C63FF) : Colors.grey.shade800,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  )),
                ),
                
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  ),
                  onPressed: () {
                    if (_currentPage == 2) {
                      _finishOnboarding();
                    } else {
                      _pageController.nextPage(duration: const Duration(milliseconds: 500), curve: Curves.ease);
                    }
                  },
                  child: Text(_currentPage == 2 ? "Los geht's" : "Weiter", style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                )
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildPage({required IconData icon, required Color color, required String title, required String description}) {
    return Padding(
      padding: const EdgeInsets.all(40.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 120, color: color),
          const SizedBox(height: 40),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 20),
          Text(description, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.grey, height: 1.5)),
        ],
      ),
    );
  }
}

// --- MAIN APP (MainNavigationScreen) ---
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  Timer? _heartbeat;

  final List<Widget> _pages = [
    const AlarmScreen(), 
    const SleepSoundScreen(), 
    const StatsScreen(), 
    const MaskSettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    onAlarmTriggered = _triggerAlarmScreen; // Callback zuweisen
    _startHeartbeat(); 
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();

    _heartbeat = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }

      final now = DateTime.now();
      final currentTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      final todayStr = '${now.day}.${now.month}.${now.year}';

      bool anySunriseActive = false;

      for (var alarm in myAlarms) {
        if (alarm['isActive'] == true) {
          
          List<String> parts = alarm['time'].split(':');
          DateTime alarmDate = DateTime(now.year, now.month, now.day, int.parse(parts[0]), int.parse(parts[1]));
          
          if (alarmDate.isBefore(now) && alarm['time'] != currentTime) {
            alarmDate = alarmDate.add(const Duration(days: 1));
          }
          
          DateTime sunriseDate = alarmDate.subtract(Duration(minutes: globalLightPreStart.toInt()));

          if ((now.isAfter(sunriseDate) || now.isAtSameMomentAs(sunriseDate)) && now.isBefore(alarmDate)) {
            anySunriseActive = true;
          }
        }
      }

      bool finalSunriseState = anySunriseActive || isTestingSunrise;
      if (isSunriseActive.value != finalSunriseState) {
        isSunriseActive.value = finalSunriseState;
      }
    });
  }

  void _triggerAlarmScreen(String label) async {
    FlutterRingtonePlayer().playAlarm(looping: true, volume: 1.0);
    bool? hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator == true) Vibration.vibrate(pattern: [500, 1000, 500, 1000], repeat: 1);

    if (!mounted) return;
    showDialog(
      context: context, 
      barrierDismissible: false, 
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A), 
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Column(
          children: [
            const SonilloLogo(), 
            const SizedBox(height: 20),
            const Icon(Icons.alarm_on, color: Color(0xFF6C63FF), size: 50), 
            const SizedBox(height: 10),
            const Text('WAKE UP!', style: TextStyle(color: Color(0xFF6C63FF), fontSize: 28, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text('Dein Wecker "$label" klingelt!', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18)),
        actions: [
          Column(
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.snooze),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white, 
                    side: const BorderSide(color: Colors.grey), 
                    padding: const EdgeInsets.symmetric(vertical: 15), 
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                  ),
                  onPressed: () {
                    FlutterRingtonePlayer().stop();
                    Vibration.cancel();
                    Navigator.pop(context);
                    DateTime snoozeTime = DateTime.now().add(const Duration(minutes: 5));
                    String formattedSnooze = '${snoozeTime.hour.toString().padLeft(2, '0')}:${snoozeTime.minute.toString().padLeft(2, '0')}';
                    setState(() { myAlarms.insert(0, {'time': formattedSnooze, 'label': 'Snooze ($label)', 'isActive': true, 'lastTriggered': ''}); });
                    saveAlarms();
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Snooze aktiviert: Noch 5 Minuten! 💤')));
                  },
                  label: const Text('5 Min Snooze', style: TextStyle(fontSize: 16)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF), 
                    padding: const EdgeInsets.symmetric(vertical: 15), 
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                  ),
                  onPressed: () {
                    FlutterRingtonePlayer().stop();
                    Vibration.cancel(); 
                    Navigator.pop(context);
                  },
                  child: const Text('Ausschalten', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          )
        ],
      )
    );
  }

  @override
  void dispose() { 
    _heartbeat?.cancel(); 
    super.dispose(); 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.alarm), label: 'Wecker'), 
          BottomNavigationBarItem(icon: Icon(Icons.waves), label: 'Sounds'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Profil'), 
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Maske'),
        ],
      ),
    );
  }
}

// --- TAB 1: DER WECKER ---
class AlarmScreen extends StatefulWidget {
  const AlarmScreen({super.key});

  @override
  State<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends State<AlarmScreen> {
  void _showIOSStyleTimePicker() {
    DateTime selectedTime = DateTime.now();
    TextEditingController nameController = TextEditingController(text: 'Neuer Wecker');

    showDialog(
      context: context,
      builder: (BuildContext builder) {
        return Dialog(
          backgroundColor: const Color(0xFF1A1A1A), 
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            width: 350, 
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context), 
                      child: const Text('Abbrechen', style: TextStyle(color: Colors.grey, fontSize: 16))
                    ),
                    TextButton(
                      onPressed: () {
                        String formattedTime = '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}';
                        String alarmName = nameController.text.trim();
                        if (alarmName.isEmpty) alarmName = "Wecker"; 
                        setState(() { myAlarms.insert(0, {'time': formattedTime, 'label': alarmName, 'isActive': true, 'lastTriggered': ''}); });
                           _saveAlarmsWithCheck(); 
                        Navigator.pop(context); 
                      },
                      child: const Text('Speichern', style: TextStyle(color: Color(0xFF6C63FF), fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                TextField(
                  controller: nameController, 
                  style: const TextStyle(color: Colors.white, fontSize: 18), 
                  decoration: InputDecoration(
                    labelText: 'Name', 
                    labelStyle: const TextStyle(color: Colors.grey),
                    enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF6C63FF)))
                  ),
                ),
                const SizedBox(height: 25), 
                SizedBox(
                  height: 200, 
                  child: CupertinoTheme(
                    data: const CupertinoThemeData(brightness: Brightness.dark), 
                    child: CupertinoDatePicker(
                      mode: CupertinoDatePickerMode.time, 
                      use24hFormat: true,
                      onDateTimeChanged: (DateTime newDate) {
                        selectedTime = newDate;
                      },
                    ),
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  // --- NEU: Prüft beim Speichern, ob die Maske verbunden ist und warnt den User ---
  void _saveAlarmsWithCheck() {
    saveAlarms();
    if (!isConnectedToBLE.value) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Lokal gespeichert. Bitte im Tab "Maske" verbinden, um den Wecker an die Maske zu senden!'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 4),
        )
      );
    }
  }

  void _startPowernap(int minutes) {
    DateTime wakeUpTime = DateTime.now().add(Duration(minutes: minutes));
    String formattedTime = '${wakeUpTime.hour.toString().padLeft(2, '0')}:${wakeUpTime.minute.toString().padLeft(2, '0')}';
    setState(() { myAlarms.insert(0, {'time': formattedTime, 'label': 'Powernap ($minutes Min)', 'isActive': true, 'lastTriggered': ''}); });
    saveAlarms(); 
    
    // Dynamische Nachricht je nach Verbindungsstatus
    String msg = isConnectedToBLE.value 
        ? 'Powernap auf $formattedTime Uhr an Maske gesendet' 
        : 'Powernap lokal. Bitte Maske im Tab "Maske" verbinden!';
    Color bgColor = isConnectedToBLE.value ? const Color(0xFF6C63FF) : Colors.orange;
    
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg), 
      backgroundColor: bgColor
    ));
  }

  void _toggleAlarm(int index, bool newValue) { 
    setState(() { myAlarms[index]['isActive'] = newValue; }); 
    _saveAlarmsWithCheck(); 
  }

  void _deleteAlarm(int index) { 
    setState(() { myAlarms.removeAt(index); }); 
    _saveAlarmsWithCheck(); 
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const SonilloLogo(), 
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: isConnectedToBLE,
            builder: (context, isConnected, child) {
              return IconButton(
                icon: Icon(
                  Icons.bluetooth_searching, 
                  color: isConnected ? Colors.greenAccent : const Color(0xFF6C63FF)
                ), 
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const ScanScreen()))
              );
            },
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (myAlarms.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40.0),
              child: Column(
                children: [
                  Icon(Icons.alarm_off, size: 64, color: Colors.grey.shade600),
                  const SizedBox(height: 16),
                  Text('Keine Wecker vorhanden', style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                ],
              ),
            ),
          for (int i = 0; i < myAlarms.length; i++) 
            _buildAlarmCard(myAlarms[i]['time'], myAlarms[i]['label'], myAlarms[i]['isActive'], i),
          const SizedBox(height: 30), 
          const Text('Sonillo Schnellstart', style: TextStyle(color: Colors.grey, fontSize: 14)), 
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly, 
            children: [
              _buildPowernapButton(1), 
              _buildPowernapButton(15), 
              _buildPowernapButton(30)
            ]
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _showIOSStyleTimePicker, 
            icon: const Icon(Icons.add), 
            label: const Text('Neuen Alarm stellen', style: TextStyle(fontSize: 16)), 
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6C63FF), 
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
            ),
          )
        ],
      ),
    );
  }

  Widget _buildPowernapButton(int minutes) {
    return ActionChip(
      label: Text('$minutes Min'), 
      backgroundColor: const Color(0xFF1A1A1A), 
      labelStyle: const TextStyle(color: Colors.white), 
      side: const BorderSide(color: Color(0xFF6C63FF)), 
      onPressed: () => _startPowernap(minutes)
    );
  }

  Widget _buildAlarmCard(String time, String label, bool isActive, int index) {
    return Dismissible(
      key: UniqueKey(), 
      direction: DismissDirection.endToStart, 
      onDismissed: (_) => _deleteAlarm(index),
      background: Container(
        alignment: Alignment.centerRight, 
        padding: const EdgeInsets.only(right: 20), 
        decoration: BoxDecoration(
          color: Colors.redAccent, 
          borderRadius: BorderRadius.circular(20)
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: Card(
        color: const Color(0xFF1A1A1A), 
        margin: const EdgeInsets.only(bottom: 16), 
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start, 
                children: [
                  Text(
                    time, 
                    style: TextStyle(
                      fontSize: 40, 
                      fontWeight: FontWeight.bold, 
                      color: isActive ? Colors.white : Colors.grey.shade600
                    )
                  ),
                  Text(
                    label, 
                    style: TextStyle(
                      fontSize: 14, 
                      color: isActive ? Colors.grey : Colors.grey.shade700
                    )
                  ),
                ]
              ),
              Switch(
                value: isActive, 
                activeColor: const Color(0xFF6C63FF), 
                onChanged: (val) => _toggleAlarm(index, val)
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- TAB 2: SONILLO SOUNDSCAPES (UI-Platzhalter, echte Sounds via A2DP) ---
class SleepSoundScreen extends StatefulWidget {
  const SleepSoundScreen({super.key});

  @override
  State<SleepSoundScreen> createState() => _SleepSoundScreenState();
}

class _SleepSoundScreenState extends State<SleepSoundScreen> {
  int? activeIndex;
  Timer? sleepTimer;
  int remainingMinutes = 0;

  void _toggleSound(int index) {
    if (activeIndex == index) {
      setState(() { activeIndex = null; remainingMinutes = 0; });
      sleepTimer?.cancel();
    } else {
      setState(() { activeIndex = index; remainingMinutes = 20; });
      sleepTimer?.cancel();
      sleepTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
        if (!mounted) { timer.cancel(); return; }
        setState(() {
          remainingMinutes--;
          if (remainingMinutes <= 0) {
            activeIndex = null;
            timer.cancel();
          }
        });
      });
    }
  }

  @override
  void dispose() { sleepTimer?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const SonilloLogo()),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 10),
            child: Text('Sonillo Soundscapes', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          ),
          if (activeIndex != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C63FF).withOpacity(0.2), 
                  borderRadius: BorderRadius.circular(15), 
                  border: Border.all(color: const Color(0xFF6C63FF))
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Spielt Audio...', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    Text('Fade-out in $remainingMinutes Min', style: const TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
            ),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2, 
              padding: const EdgeInsets.all(16), 
              crossAxisSpacing: 16, 
              mainAxisSpacing: 16,
              children: [
                _buildSoundCard(0, Icons.water_drop, 'Sanfter Regen'),
                _buildSoundCard(1, Icons.air, 'White Noise'),
                _buildSoundCard(2, Icons.forest, 'Sommerwald'),
                _buildSoundCard(3, Icons.waves, 'Ozean'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSoundCard(int index, IconData icon, String title) {
    bool isSelected = activeIndex == index;
    return GestureDetector(
      onTap: () => _toggleSound(index),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF6C63FF).withOpacity(0.2) : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? const Color(0xFF6C63FF) : Colors.transparent, width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 50, color: isSelected ? const Color(0xFF6C63FF) : Colors.white),
            const SizedBox(height: 10),
            Text(
              title, 
              style: TextStyle(
                fontSize: 16, 
                color: isSelected ? const Color(0xFF6C63FF) : Colors.white, 
                fontWeight: FontWeight.bold
              )
            ),
          ],
        ),
      ),
    );
  }
}

// --- TAB 3: STATISTIKEN (Echte Daten aus SharedPreferences) ---
class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const SonilloLogo()), 
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Dein Sonillo Profil', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 5),
            const Text('Synchronisiert mit deiner Maske', style: TextStyle(color: Colors.grey, fontSize: 16)),
            const SizedBox(height: 30),
            Container(
              height: 250, 
              padding: const EdgeInsets.all(16), 
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A), 
                borderRadius: BorderRadius.circular(20)
              ),
              child: Center(
                child: Text(
                  'Schlaf-Daten werden von der Maske erfasst\n(TODO: Sleep Tracking implementieren)',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
              ),
            ),
            const SizedBox(height: 30),
            const Text('Statistiken', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), 
            const SizedBox(height: 15),
            ListTile(
              contentPadding: const EdgeInsets.all(15), 
              tileColor: const Color(0xFF1A1A1A), 
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)), 
              leading: const Icon(Icons.bedtime, color: Colors.orangeAccent),
              title: const Text('Alarme erstellt', style: TextStyle(fontWeight: FontWeight.bold)),
              trailing: Text('${myAlarms.length}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF6C63FF))),
            )
          ],
        ),
      ),
    );
  }
}

// --- TAB 4: MASKE EINSTELLUNGEN ---
class MaskSettingsScreen extends StatefulWidget {
  const MaskSettingsScreen({super.key});

  @override
  State<MaskSettingsScreen> createState() => _MaskSettingsScreenState();
}

class _MaskSettingsScreenState extends State<MaskSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const SonilloLogo()),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Maske Einstellungen', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            
            // Licht-Vorlauf Slider
            Card(
              color: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Licht-Vorlauf vor Wecker', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: globalLightPreStart,
                            min: 0,
                            max: 60,
                            activeColor: const Color(0xFF6C63FF),
                            onChanged: (value) {
                              setState(() { globalLightPreStart = value; });
                              saveSettings();
                            },
                          ),
                        ),
                        Text('${globalLightPreStart.toInt()} min', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF6C63FF))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 20),
            
            // Bluetooth Status
            Card(
              color: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Bluetooth Verbindung', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 15),
                    ValueListenableBuilder<bool>(
                      valueListenable: isConnectedToBLE,
                      builder: (context, isConnected, child) {
                        return Row(
                          children: [
                            Icon(
                              isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                              color: isConnected ? Colors.greenAccent : Colors.redAccent,
                              size: 32,
                            ),
                            const SizedBox(width: 15),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isConnected ? 'Verbunden' : 'Nicht verbunden',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: isConnected ? Colors.greenAccent : Colors.redAccent,
                                    ),
                                  ),
                                  Text(
                                    isConnected ? connectedDevice?.platformName ?? 'Unbekannt' : 'Tap zum Verbinden',
                                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            if (isConnected)
                              ElevatedButton(
                                onPressed: disconnectFromESP32,
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                child: const Text('Trennen'),
                              )
                            else
                              ElevatedButton(
                                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const ScanScreen())),
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
                                child: const Text('Verbinden'),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- BLE SCAN SCREEN ---
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  @override
  void initState() {
    super.initState();
    _requestPermissionsAndStartScan();
  }

  Future<void> _requestPermissionsAndStartScan() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    
    if (statuses[Permission.bluetoothScan]?.isGranted ?? false) {
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Maske verbinden')),
      body: StreamBuilder<List<ScanResult>>(
        stream: FlutterBluePlus.scanResults,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          List<ScanResult> results = snapshot.data ?? [];
          List<ScanResult> filtered = results.where((r) => r.device.platformName.contains('SonilloMask')).toList();

          if (filtered.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bluetooth_searching, size: 64, color: Colors.grey.shade600),
                  const SizedBox(height: 16),
                  const Text('Keine Maske gefunden', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: () {
                      FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
                      setState(() {});
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Erneut suchen'),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              ScanResult result = filtered[index];
              return ListTile(
                title: Text(result.device.platformName),
                subtitle: Text(result.device.remoteId.toString()),
                onTap: () {
                  connectToESP32(result.device);
                  Navigator.pop(context);
                },
              );
            },
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    FlutterBluePlus.stopScan();
    super.dispose();
  }
}
