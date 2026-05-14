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

// --- GLOBALE VARIABLEN ---
List<Map<String, dynamic>> myAlarms = [];
SharedPreferences? prefs;

// Globale Einstellungen
double globalLightPreStart = 15.0;
bool globalLucidEnabled = false;
bool isFirstLaunch = true; // NEU: Prüft, ob die App zum ersten Mal startet

// Der Echtzeit-Schalter für das Logo
ValueNotifier<bool> isSunriseActive = ValueNotifier(false);
bool isTestingSunrise = false; 

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  _loadData();
  runApp(const SonilloApp());
}

void _loadData() {
  // Check Onboarding
  isFirstLaunch = prefs?.getBool('isFirstLaunch') ?? true;

  // Check Alarme
  String? alarmsJson = prefs?.getString('alarms');
  if (alarmsJson != null) {
    List<dynamic> decoded = jsonDecode(alarmsJson);
    myAlarms = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
    for (var alarm in myAlarms) {
      if (!alarm.containsKey('lastSunrise')) alarm['lastSunrise'] = '';
    }
  } else {
    myAlarms = [{'time': '07:00', 'label': 'Guten Morgen', 'isActive': true, 'lastTriggered': '', 'lastSunrise': ''}];
  }
  
  // Check Settings
  globalLightPreStart = prefs?.getDouble('lightPreStart') ?? 15.0;
  globalLucidEnabled = prefs?.getBool('lucidEnabled') ?? false;
}

void saveAlarms() { prefs?.setString('alarms', jsonEncode(myAlarms)); }
void saveSettings() {
  prefs?.setDouble('lightPreStart', globalLightPreStart);
  prefs?.setBool('lucidEnabled', globalLucidEnabled);
}
void completeOnboarding() {
  prefs?.setBool('isFirstLaunch', false);
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
        brightness: Brightness.dark, primaryColor: const Color(0xFF6C63FF), scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0, centerTitle: true),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(backgroundColor: Color(0xFF1A1A1A), selectedItemColor: Color(0xFF6C63FF), unselectedItemColor: Colors.grey, type: BottomNavigationBarType.fixed),
      ),
      // DER WEICHENSTELLER: Onboarding oder direkt zur App?
      home: isFirstLaunch ? const OnboardingScreen() : const MainNavigationScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- NEU: DAS PREMIUM ONBOARDING ---
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
                icon: Icons.bedtime, color: const Color(0xFF6C63FF),
                title: 'Willkommen bei Sonillo',
                description: 'Verabschiede dich von schrillen Weckern. Erlebe die sanfteste Art, in den Tag zu starten.',
              ),
              _buildPage(
                icon: Icons.bluetooth_connected, color: Colors.blueAccent,
                title: 'Smart & Verbunden',
                description: 'Kopple deine Sonillo Maske über den Radar-Tab, um das volle Potenzial deines Schlafs freizuschalten.',
              ),
              _buildPage(
                icon: Icons.wb_twilight, color: Colors.orangeAccent,
                title: 'Dein persönlicher Sonnenaufgang',
                description: 'Die Maske dimmt das Licht langsam hoch, bevor dein Wecker klingelt. Du wachst erholt auf.',
              ),
            ],
          ),
          
          // Navigation unten (Punkte & Button)
          Positioned(
            bottom: 50, left: 20, right: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Die kleinen Punkte
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
                
                // Der Weiter / Start Button
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  ),
                  onPressed: () {
                    if (_currentPage == 2) {
                      _finishOnboarding(); // App starten!
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

// --- AB HIER: DIE NORMALE APP (MainNavigationScreen etc.) ---
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  Timer? _heartbeat;

  final List<Widget> _pages = [
    const AlarmScreen(), const SleepSoundScreen(), const StatsScreen(), const MaskSettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
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
          
          if (alarm['time'] == currentTime && alarm['lastTriggered'] != todayStr) {
            alarm['lastTriggered'] = todayStr;
            saveAlarms();
            _triggerAlarmScreen(alarm['label']);
          }

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
      context: context, barrierDismissible: false, 
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.grey), padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
                  onPressed: () {
                    FlutterRingtonePlayer().stop();
                    Vibration.cancel();
                    Navigator.pop(context);
                    DateTime snoozeTime = DateTime.now().add(const Duration(minutes: 5));
                    String formattedSnooze = '${snoozeTime.hour.toString().padLeft(2, '0')}:${snoozeTime.minute.toString().padLeft(2, '0')}';
                    setState(() { myAlarms.insert(0, {'time': formattedSnooze, 'label': 'Snooze ($label)', 'isActive': true, 'lastTriggered': '', 'lastSunrise': ''}); });
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
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF), padding: const EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
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
  void dispose() { _heartbeat?.cancel(); super.dispose(); }

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
          backgroundColor: const Color(0xFF1A1A1A), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            width: 350, padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen', style: TextStyle(color: Colors.grey, fontSize: 16))),
                    TextButton(
                      onPressed: () {
                        String formattedTime = '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}';
                        String alarmName = nameController.text.trim();
                        if (alarmName.isEmpty) alarmName = "Wecker"; 
                        setState(() { myAlarms.insert(0, {'time': formattedTime, 'label': alarmName, 'isActive': true, 'lastTriggered': '', 'lastSunrise': ''}); });
                        saveAlarms(); Navigator.pop(context); 
                      },
                      child: const Text('Speichern', style: TextStyle(color: Color(0xFF6C63FF), fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                TextField(controller: nameController, style: const TextStyle(color: Colors.white, fontSize: 18), decoration: InputDecoration(labelText: 'Name', labelStyle: const TextStyle(color: Colors.grey), prefixIcon: const Icon(Icons.edit, color: Colors.grey), filled: true, fillColor: const Color(0xFF2A2A2A), border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none))),
                const SizedBox(height: 25), 
                SizedBox(height: 200, child: CupertinoTheme(data: const CupertinoThemeData(brightness: Brightness.dark), child: CupertinoDatePicker(mode: CupertinoDatePickerMode.time, use24hFormat: true, initialDateTime: DateTime.now(), onDateTimeChanged: (newTime) => selectedTime = newTime))),
              ],
            ),
          ),
        );
      },
    );
  }

  void _startPowernap(int minutes) {
    DateTime wakeUpTime = DateTime.now().add(Duration(minutes: minutes));
    String formattedTime = '${wakeUpTime.hour.toString().padLeft(2, '0')}:${wakeUpTime.minute.toString().padLeft(2, '0')}';
    setState(() { myAlarms.insert(0, {'time': formattedTime, 'label': 'Powernap ($minutes Min)', 'isActive': true, 'lastTriggered': '', 'lastSunrise': ''}); });
    saveAlarms(); 
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Powernap auf $formattedTime Uhr'), backgroundColor: const Color(0xFF6C63FF)));
  }

  void _toggleAlarm(int index, bool newValue) { setState(() { myAlarms[index]['isActive'] = newValue; }); saveAlarms(); }
  void _deleteAlarm(int index) { setState(() { myAlarms.removeAt(index); }); saveAlarms(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const SonilloLogo(), 
        actions: [IconButton(icon: const Icon(Icons.bluetooth_searching, color: Color(0xFF6C63FF)), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const ScanScreen()))), const SizedBox(width: 10)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (int i = 0; i < myAlarms.length; i++) _buildAlarmCard(myAlarms[i]['time'], myAlarms[i]['label'], myAlarms[i]['isActive'], i),
          const SizedBox(height: 30), const Text('Sonillo Schnellstart', style: TextStyle(color: Colors.grey, fontSize: 14)), const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [_buildPowernapButton(1), _buildPowernapButton(15), _buildPowernapButton(30)]),
          const SizedBox(height: 20),
          ElevatedButton.icon(onPressed: _showIOSStyleTimePicker, icon: const Icon(Icons.add), label: const Text('Neuen Alarm stellen', style: TextStyle(fontSize: 16)), style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16), backgroundColor: const Color(0xFF2A2A2A), foregroundColor: const Color(0xFF6C63FF), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)))),
        ],
      ),
    );
  }

  Widget _buildPowernapButton(int minutes) {
    return ActionChip(label: Text('$minutes Min'), backgroundColor: const Color(0xFF1A1A1A), labelStyle: const TextStyle(color: Colors.white), side: const BorderSide(color: Color(0xFF6C63FF)), onPressed: () => _startPowernap(minutes));
  }

  Widget _buildAlarmCard(String time, String label, bool isActive, int index) {
    return Dismissible(
      key: UniqueKey(), direction: DismissDirection.endToStart, onDismissed: (_) => _deleteAlarm(index),
      background: Container(alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(20)), child: const Icon(Icons.delete, color: Colors.white)),
      child: Card(
        color: const Color(0xFF1A1A1A), margin: const EdgeInsets.only(bottom: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(time, style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: isActive ? Colors.white : Colors.grey.shade700)), Text(label, style: const TextStyle(color: Colors.grey, fontSize: 16))]),
              Switch(value: isActive, activeColor: const Color(0xFF6C63FF), onChanged: (val) => _toggleAlarm(index, val)),
            ],
          ),
        ),
      ),
    );
  }
}

// --- TAB 2: SONILLO SOUNDSCAPES ---
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
                decoration: BoxDecoration(color: const Color(0xFF6C63FF).withOpacity(0.2), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFF6C63FF))),
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
              crossAxisCount: 2, padding: const EdgeInsets.all(16), crossAxisSpacing: 16, mainAxisSpacing: 16,
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
            Text(title, style: TextStyle(fontSize: 16, color: isSelected ? const Color(0xFF6C63FF) : Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

// --- TAB 3: STATISTIKEN ---
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
            const Text('Ø 7h 20m Schlafenszeit', style: TextStyle(color: Colors.grey, fontSize: 16)),
            const SizedBox(height: 30),
            Container(
              height: 250, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(20)),
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround, maxY: 10, barTouchData: BarTouchData(enabled: false),
                  titlesData: FlTitlesData(
                    show: true, bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (double value, TitleMeta meta) {
                          const style = TextStyle(color: Colors.grey, fontSize: 12);
                          String text;
                          switch (value.toInt()) { case 0: text='Mo'; break; case 1: text='Di'; break; case 2: text='Mi'; break; case 3: text='Do'; break; case 4: text='Fr'; break; case 5: text='Sa'; break; case 6: text='So'; break; default: text=''; break; }
                          return SideTitleWidget(meta: meta, child: Text(text, style: style));
                        },
                      ),
                    ),
                    leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: 2, getDrawingHorizontalLine: (value) => FlLine(color: Colors.grey.withOpacity(0.2), strokeWidth: 1)),
                  borderData: FlBorderData(show: false),
                  barGroups: [_makeBarData(0, 6.5), _makeBarData(1, 7.0), _makeBarData(2, 5.5), _makeBarData(3, 8.0), _makeBarData(4, 7.5), _makeBarData(5, 9.0), _makeBarData(6, 8.5)],
                ),
              ),
            ),
            const SizedBox(height: 30),
            const Text('Erfolge', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), const SizedBox(height: 15),
            ListTile(contentPadding: const EdgeInsets.all(15), tileColor: const Color(0xFF1A1A1A), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)), leading: const Icon(Icons.local_fire_department, color: Colors.orange, size: 40), title: const Text('3 Tage Streak!', style: TextStyle(fontWeight: FontWeight.bold)), subtitle: const Text('Du bist pünktlich ins Bett gegangen.'))
          ],
        ),
      ),
    );
  }

  BarChartGroupData _makeBarData(int x, double y) {
    return BarChartGroupData(x: x, barRods: [BarChartRodData(toY: y, color: const Color(0xFF6C63FF), width: 15, borderRadius: const BorderRadius.only(topLeft: Radius.circular(5), topRight: Radius.circular(5)), backDrawRodData: BackgroundBarChartRodData(show: true, toY: 10, color: const Color(0xFF2A2A2A)))]);
  }
}

// --- TAB 4: EINSTELLUNGEN ---
class MaskSettingsScreen extends StatefulWidget {
  const MaskSettingsScreen({super.key});

  @override
  State<MaskSettingsScreen> createState() => _MaskSettingsScreenState();
}

class _MaskSettingsScreenState extends State<MaskSettingsScreen> {
  bool isAdvancedMode = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const SonilloLogo()), 
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const ListTile(leading: Icon(Icons.battery_4_bar, color: Colors.green), title: Text('Akku der Sonillo Maske'), trailing: Text('85%', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold))),
          const Divider(color: Colors.grey),
          
          Container(
            margin: const EdgeInsets.only(bottom: 20),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.wb_twilight),
              label: const Text('Signal-Test: Logo-Farbe testen'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2A2A2A), foregroundColor: Colors.orangeAccent,
                padding: const EdgeInsets.all(15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
              ),
              onPressed: () {
                isTestingSunrise = true;
                isSunriseActive.value = true; 
                
                Future.delayed(const Duration(seconds: 5), () {
                  isTestingSunrise = false;
                  isSunriseActive.value = false; 
                });
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Sonillo Maske: Sonnenaufgang simuliert!'),
                    backgroundColor: const Color(0xFF2A2A2A), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)), duration: const Duration(seconds: 3),
                  )
                );
              },
            ),
          ),

          SwitchListTile(title: const Text('Sonillo Premium-Einstellungen', style: TextStyle(fontWeight: FontWeight.bold)), subtitle: const Text('Klarträume, Licht-Vorlauf & mehr'), value: isAdvancedMode, activeColor: const Color(0xFF6C63FF), onChanged: (bool value) => setState(() => isAdvancedMode = value)),
          if (isAdvancedMode) ...[
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 20), padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.5))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Licht-Vorlaufzeit', style: TextStyle(color: Colors.grey, fontSize: 14)), 
                  Text('Startet ${globalLightPreStart.toInt()} Min. vor dem Wecker', style: const TextStyle(fontSize: 16)),
                  Slider(
                    value: globalLightPreStart, min: 5, max: 45, divisions: 8, activeColor: const Color(0xFF6C63FF), 
                    onChanged: (val) { setState(() => globalLightPreStart = val); saveSettings(); }
                  ),
                  const Divider(color: Colors.grey),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero, title: const Text('Lucid Dream (Klartraum) Modus'), subtitle: const Text('Leichtes rotes Blitzen in der REM-Phase'), 
                    value: globalLucidEnabled, activeColor: Colors.redAccent, 
                    onChanged: (bool value) { setState(() => globalLucidEnabled = value); saveSettings(); }
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// --- BLUETOOTH RADAR ---
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  late StreamSubscription<List<ScanResult>> _scanResultsSubscription;
  late StreamSubscription<bool> _isScanningSubscription;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndStart();
  }

  Future<void> _checkPermissionsAndStart() async {
    Map<Permission, PermissionStatus> statuses = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.location].request();
    if (statuses[Permission.bluetoothScan]!.isGranted) _startScan();
  }

  void _startScan() async {
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) { setState(() { _scanResults = results; }); });
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((state) { setState(() { _isScanning = state; }); });
    try { await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15)); } catch (e) { print("Scan Error: $e"); }
  }

  @override
  void dispose() { FlutterBluePlus.stopScan(); _scanResultsSubscription.cancel(); _isScanningSubscription.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const SonilloLogo(), backgroundColor: Colors.transparent),
      body: Column(
        children: [
          Padding(padding: const EdgeInsets.all(20.0), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [if (_isScanning) const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Color(0xFF6C63FF), strokeWidth: 3)), const SizedBox(width: 15), Text(_isScanning ? 'Suche nach Masken...' : 'Suche beendet.', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))])),
          Expanded(child: _scanResults.isEmpty ? const Center(child: Text('Keine Geräte gefunden.\n(PC Emulator normal!)', textAlign: TextAlign.center)) : ListView.builder(itemCount: _scanResults.length, itemBuilder: (context, index) { final device = _scanResults[index].device; return ListTile(title: Text(device.advName.isEmpty ? 'Unbekannt' : device.advName), subtitle: Text(device.remoteId.toString())); })),
        ],
      ),
    );
  }
}