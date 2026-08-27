import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

const _defaultCategories = <String>[
  'Grocery',
  'Bills',
  'Shopping',
  'Online shopping',
  'Salary',
  'Investment',
  'Pets',
  'Restaurant',
  'Telecommunication',
  'Car care',
  'Toys and gifts',
  'Electronics',
  'Personal transfer',
  'Utilities',
  'Other',
  'Rent & Housing',
  'Education',
  'Dependents',
  'Loans & Debt',
  'Household Help'
];
const _supabaseUrl = 'https://mmdtntkrxrthkamldawd.supabase.co';
const _supabaseKey = 'sb_publishable_DkDDvlA5HqXtqO2T9htjRQ_FnsWUUS3';
const _cloudKeepAliveTask = 'my-expensia-cloud-keep-alive';
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseKey);
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return true;
    try {
      await Supabase.instance.client
          .from('flutter_app_state')
          .select('user_id')
          .eq('user_id', user.id)
          .limit(1);
      return true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: _supabaseUrl, publishableKey: _supabaseKey);
  await Workmanager().initialize(backgroundDispatcher);
  await Workmanager().registerPeriodicTask(
      _cloudKeepAliveTask, _cloudKeepAliveTask,
      frequency: const Duration(days: 5),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep);
  runApp(const App());
}

enum Currency { sar, usd, jod }

extension CurrencyInfo on Currency {
  String get nameLabel =>
      this == Currency.usd ? 'USD (\$)' : name.toUpperCase();
  String get symbol => this == Currency.usd ? '\$' : name.toUpperCase();
}

class PlanReminderService {
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Future<void> initialize() async {
    if (_ready) return;
    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Riyadh'));
    const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'));
    await _notifications.initialize(settings: settings);
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _ready = true;
  }

  Future<void> schedule(
      List<MonthlyPlan> plans, List<Portfolio> portfolios) async {
    if (!_ready) return;
    for (var id = 9000; id < 9010; id++) {
      await _notifications.cancel(id: id);
    }
    final now = tz.TZDateTime.now(tz.local);
    var notificationId = 9000;
    for (var offset = 0; offset < 3; offset++) {
      final month = DateTime(now.year, now.month + offset);
      final lastDay = DateTime(month.year, month.month + 1, 0).day;
      final days = <int>{if (lastDay >= 30) 30, lastDay};
      for (final day in days) {
        final target = tz.TZDateTime(tz.local, month.year, month.month, day, 9);
        if (!target.isAfter(now)) continue;
        final pending = plans
            .where((plan) => !_planCreatedInMonth(plan, portfolios, target))
            .toList();
        if (pending.isEmpty) continue;
        final names = pending.map((plan) => plan.description).join(', ');
        await _notifications.zonedSchedule(
            id: notificationId++,
            title: 'Monthly plans pending',
            body: 'Create: $names',
            scheduledDate: target,
            notificationDetails: const NotificationDetails(
                android: AndroidNotificationDetails(
                    'monthly_plan_reminders', 'Monthly plan reminders',
                    channelDescription:
                        'Reminders for monthly plans that have not been created',
                    importance: Importance.high,
                    priority: Priority.high)),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle);
      }
    }
  }
}

bool _planCreatedInMonth(
    MonthlyPlan plan, List<Portfolio> portfolios, DateTime date) {
  final month = '${date.year}-${date.month.toString().padLeft(2, '0')}';
  if (plan.lastCreatedMonth == month) return true;
  final matches = portfolios.where((item) => item.id == plan.portfolioId);
  if (matches.isEmpty) return false;
  final portfolio = matches.first;
  return portfolio.transactions.any((tx) =>
      !tx.inflow &&
      tx.description == plan.description &&
      tx.amount == plan.amount &&
      tx.createdAt.year == date.year &&
      tx.createdAt.month == date.month);
}

class Tx {
  Tx(
      {required this.id,
      required this.description,
      required this.category,
      required this.amount,
      required this.inflow,
      required this.createdAt,
      this.transferId});
  final String id, description, category;
  final double amount;
  final bool inflow;
  final DateTime createdAt;
  final String? transferId;
  Map<String, dynamic> json() => {
        'id': id,
        'description': description,
        'category': category,
        'amount': amount,
        'inflow': inflow,
        'createdAt': createdAt.toIso8601String(),
        'transferId': transferId
      };
  factory Tx.fromJson(Map<String, dynamic> x) => Tx(
      id: x['id'],
      description: x['description'],
      category: x['category'],
      amount: (x['amount'] as num).toDouble(),
      inflow: x['inflow'],
      createdAt: DateTime.parse(x['createdAt']),
      transferId: x['transferId']);
}

class MonthlyPlan {
  MonthlyPlan(
      {required this.id,
      required this.description,
      required this.category,
      required this.amount,
      required this.dueDay,
      required this.portfolioId,
      this.savingsTransfer = false,
      this.destinationPortfolioId,
      this.recurring = true,
      this.lastCreatedMonth});
  final String id, description, category, portfolioId;
  final double amount;
  final int dueDay;
  final bool savingsTransfer, recurring;
  final String? destinationPortfolioId, lastCreatedMonth;
  Map<String, dynamic> json() => {
        'id': id,
        'description': description,
        'category': category,
        'amount': amount,
        'dueDay': dueDay,
        'portfolioId': portfolioId,
        'savingsTransfer': savingsTransfer,
        'destinationPortfolioId': destinationPortfolioId,
        'recurring': recurring,
        'lastCreatedMonth': lastCreatedMonth
      };
  factory MonthlyPlan.fromJson(Map<String, dynamic> x) => MonthlyPlan(
      id: x['id'],
      description: x['description'],
      category: x['category'],
      amount: (x['amount'] as num).toDouble(),
      dueDay: (x['dueDay'] as num? ?? 1).toInt(),
      portfolioId: x['portfolioId'],
      savingsTransfer: x['savingsTransfer'] ?? false,
      destinationPortfolioId: x['destinationPortfolioId'],
      recurring: x['recurring'] ?? true,
      lastCreatedMonth: x['lastCreatedMonth']);
}

class Portfolio {
  Portfolio(
      {required this.id,
      required this.name,
      this.opening = 0,
      this.currency = Currency.sar,
      List<Tx>? transactions,
      Map<String, double>? categoryCaps})
      : transactions = transactions ?? [],
        categoryCaps = categoryCaps ?? {};
  final String id;
  String name;
  double opening;
  Currency currency;
  List<Tx> transactions;
  Map<String, double> categoryCaps;
  double get balance =>
      opening +
      transactions.fold(0, (sum, t) => sum + (t.inflow ? t.amount : -t.amount));
  Map<String, dynamic> json() => {
        'id': id,
        'name': name,
        'opening': opening,
        'currency': currency.name,
        'transactions': transactions.map((x) => x.json()).toList(),
        'categoryCaps': categoryCaps
      };
  factory Portfolio.fromJson(Map<String, dynamic> x) => Portfolio(
      id: x['id'],
      name: x['name'],
      opening: (x['opening'] as num? ?? x['balance'] as num? ?? 0).toDouble(),
      currency: Currency.values.firstWhere((c) => c.name == x['currency'],
          orElse: () => Currency.sar),
      transactions: (x['transactions'] as List? ?? [])
          .map((t) => Tx.fromJson(t))
          .toList(),
      categoryCaps: (x['categoryCaps'] as Map? ?? {}).map(
          (key, value) => MapEntry(key.toString(), (value as num).toDouble())));
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const Home());
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final _prefs = SharedPreferencesAsync();
  final _secureStorage = const FlutterSecureStorage();
  final _auth = LocalAuthentication();
  final _reminders = PlanReminderService();
  final _cloud = Supabase.instance.client;
  var portfolios = <Portfolio>[];
  var monthlyPlans = <MonthlyPlan>[];
  var selected = '';
  var profileName = '';
  var email = '';
  var categories = <String>[..._defaultCategories];
  var categoryIcons = <String, int>{};
  var loading = true;
  var biometricEnabled = false;
  var locked = false;
  var cloudSynced = false;
  Portfolio get current => portfolios.firstWhere((p) => p.id == selected,
      orElse: () => portfolios.first);
  double total(bool inflow) => current.transactions
      .where((t) => t.inflow == inflow)
      .fold(0, (sum, t) => sum + t.amount);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cloud.auth.onAuthStateChange.listen((event) {
      if (event.event == AuthChangeEvent.signedIn ||
          event.event == AuthChangeEvent.initialSession) syncCloud();
      if (event.event == AuthChangeEvent.signedOut && mounted)
        setState(() => cloudSynced = false);
    });
    load();
    if (_cloud.auth.currentUser != null) syncCloud();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (biometricEnabled &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused) &&
        mounted) {
      setState(() => locked = true);
    }
  }

  void seedMonthlyPlans() {
    final source = portfolios.first;
    var reserveIndex =
        portfolios.indexWhere((p) => p.name == 'Savings / Reserves');
    if (reserveIndex < 0) {
      portfolios.add(Portfolio(
          id: 'savings_reserves',
          name: 'Savings / Reserves',
          currency: source.currency));
      reserveIndex = portfolios.length - 1;
    }
    final reserve = portfolios[reserveIndex];
    final data = [
      ['Rent reserve', 'Rent & Housing', 5833.0, true],
      ['School fees reserve', 'Education', 2250.0, true],
      ['Dependent fees reserve', 'Dependents', 1250.0, true],
      ['Existing loan installment', 'Loans & Debt', 5431.0, false],
      ['Company loan installment', 'Loans & Debt', 3750.0, false],
      ['Housemaid', 'Household Help', 1000.0, false],
      ['Groceries & food', 'Grocery', 3000.0, false],
      ['Utilities & telecom', 'Utilities', 1500.0, false],
      ['Two cars', 'Car care', 1800.0, false],
      ['Family personal expenses', 'Personal transfer', 1000.0, false],
      ['Restaurants & entertainment', 'Restaurant', 500.0, false]
    ];
    monthlyPlans = data.asMap().entries.map((entry) {
      final item = entry.value;
      final transfer = item[3] as bool;
      return MonthlyPlan(
          id: 'starter_${entry.key}',
          description: item[0] as String,
          category: item[1] as String,
          amount: item[2] as double,
          dueDay: 1,
          portfolioId: source.id,
          savingsTransfer: transfer,
          destinationPortfolioId: transfer ? reserve.id : null);
    }).toList();
  }

  void upgradeStarterPlanCategories() {
    const upgrades = {
      'Rent reserve': 'Rent & Housing',
      'School fees reserve': 'Education',
      'Dependent fees reserve': 'Dependents',
      'Existing loan installment': 'Loans & Debt',
      'Company loan installment': 'Loans & Debt',
      'Housemaid': 'Household Help'
    };
    monthlyPlans = monthlyPlans.map((plan) {
      final category = upgrades[plan.description];
      if (category == null || !plan.id.startsWith('starter_')) return plan;
      return MonthlyPlan(
          id: plan.id,
          description: plan.description,
          category: category,
          amount: plan.amount,
          dueDay: plan.dueDay,
          portfolioId: plan.portfolioId,
          savingsTransfer: plan.savingsTransfer,
          destinationPortfolioId: plan.destinationPortfolioId,
          recurring: plan.recurring,
          lastCreatedMonth: plan.lastCreatedMonth);
    }).toList();
  }

  Future<void> load() async {
    await _reminders.initialize();
    var raw = await _secureStorage.read(key: 'my_expensia_state_v1');
    if (raw == null) {
      raw = await _prefs.getString('my_expensia_state_v1');
      if (raw != null) {
        await _secureStorage.write(key: 'my_expensia_state_v1', value: raw);
        await _prefs.remove('my_expensia_state_v1');
      }
    }
    var needsStarterPlans = false;
    var needsCategoryUpgrade = false;
    if (raw != null) {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      profileName = d['name'] ?? '';
      email = d['email'] ?? '';
      biometricEnabled = d['biometricEnabled'] ?? false;
      categories = d['categoryVersion'] == 2
          ? List<String>.from(d['categories'] ?? categories)
          : <String>[..._defaultCategories];
      for (final category in _defaultCategories) {
        if (!categories.contains(category)) categories.add(category);
      }
      categoryIcons = Map<String, int>.from(d['categoryIcons'] ?? {});
      if (d['portfolios'] is List) {
        portfolios = (d['portfolios'] as List)
            .map((x) => Portfolio.fromJson(x))
            .toList();
      } else {
        portfolios = [
          Portfolio(
              id: 'default',
              name: 'My portfolio',
              opening: (d['startingPortfolio'] as num? ?? 0).toDouble(),
              currency: Currency.values.firstWhere(
                  (c) => c.name == d['currency'],
                  orElse: () => Currency.sar))
        ];
      }
      monthlyPlans = (d['monthlyPlans'] as List? ?? [])
          .map((x) => MonthlyPlan.fromJson(x))
          .toList();
      needsStarterPlans = d['monthlyPlansSeeded'] != true;
      needsCategoryUpgrade = d['monthlyPlanCategoryVersion'] != 2;
      selected = d['selectedId'] ?? portfolios.first.id;
    }
    if (portfolios.isEmpty) {
      portfolios = [Portfolio(id: 'default', name: 'My portfolio')];
      selected = 'default';
      needsStarterPlans = true;
    }
    if (needsStarterPlans) seedMonthlyPlans();
    if (needsCategoryUpgrade) upgradeStarterPlanCategories();
    if (mounted)
      setState(() {
        loading = false;
        locked = biometricEnabled;
      });
    if (needsStarterPlans || needsCategoryUpgrade) {
      await save();
    } else {
      await _reminders.schedule(monthlyPlans, portfolios);
    }
  }

  Future<void> writeSharedRecords(User user) async {
    final records = <Map<String, dynamic>>[
      {
        'user_id': user.id,
        'record_type': 'profile',
        'record_id': 'settings',
        'payload': {
          'name': profileName,
          'email': email,
          'selectedId': selected,
          'biometricEnabled': biometricEnabled
        }
      },
      {
        'user_id': user.id,
        'record_type': 'category',
        'record_id': 'all',
        'payload': {'categories': categories, 'icons': categoryIcons}
      }
    ];
    for (final portfolio in portfolios) {
      final payload = portfolio.json()..remove('transactions');
      records.add({
        'user_id': user.id,
        'record_type': 'portfolio',
        'record_id': portfolio.id,
        'payload': payload
      });
      for (final tx in portfolio.transactions) {
        records.add({
          'user_id': user.id,
          'record_type': 'transaction',
          'record_id': tx.id,
          'payload': {...tx.json(), 'portfolioId': portfolio.id},
          'deleted_at': null
        });
      }
    }
    for (final plan in monthlyPlans) {
      records.add({
        'user_id': user.id,
        'record_type': 'plan',
        'record_id': plan.id,
        'payload': plan.json()
      });
    }
    final activeTransactionIds = records
        .where((record) => record['record_type'] == 'transaction')
        .map((record) => record['record_id'] as String)
        .toSet();
    final storedTransactions = await _cloud
        .from('finance_records')
        .select('record_id')
        .eq('user_id', user.id)
        .eq('record_type', 'transaction');
    for (final stored in storedTransactions) {
      final recordId = stored['record_id'] as String;
      if (!activeTransactionIds.contains(recordId)) {
        await _cloud
            .from('finance_records')
            .update({'deleted_at': DateTime.now().toIso8601String()})
            .eq('user_id', user.id)
            .eq('record_type', 'transaction')
            .eq('record_id', recordId);
      }
    }
    await _cloud.from('finance_records').upsert(records);
  }

  Future<void> save() async {
    final data = {
      'name': profileName,
      'email': email,
      'biometricEnabled': biometricEnabled,
      'categories': categories,
      'categoryIcons': categoryIcons,
      'categoryVersion': 2,
      'selectedId': selected,
      'portfolios': portfolios.map((p) => p.json()).toList(),
      'monthlyPlans': monthlyPlans.map((p) => p.json()).toList(),
      'monthlyPlansSeeded': true,
      'monthlyPlanCategoryVersion': 2
    };
    await _secureStorage.write(
        key: 'my_expensia_state_v1', value: jsonEncode(data));
    final user = _cloud.auth.currentUser;
    if (user != null) {
      try {
        await _cloud.from('profiles').upsert({
          'id': user.id,
          'email': user.email ?? email,
          'display_name': profileName,
          'updated_at': DateTime.now().toIso8601String()
        });
      } catch (_) {}
      try {
        await _cloud.from('flutter_app_state').upsert({
          'user_id': user.id,
          'data': data,
          'updated_at': DateTime.now().toIso8601String()
        });
        await writeSharedRecords(user);
      } catch (_) {}
    }
    await _reminders.schedule(monthlyPlans, portfolios);
  }

  Future<void> syncCloud() async {
    final user = _cloud.auth.currentUser;
    if (user == null) return;
    try {
      final row = await _cloud
          .from('flutter_app_state')
          .select('data')
          .eq('user_id', user.id)
          .maybeSingle();
      if (row?['data'] is Map) {
        await _secureStorage.write(
            key: 'my_expensia_state_v1', value: jsonEncode(row!['data']));
        await load();
      } else {
        await save();
      }
      if (mounted) {
        setState(() => cloudSynced = true);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cloud sync connected.')));
      }
    } catch (_) {
      if (mounted) {
        setState(() => cloudSynced = false);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cloud sync could not connect.')));
      }
    }
  }

  Future<void> connectCloud() async {
    if (_cloud.auth.currentUser != null) {
      await syncCloud();
      return;
    }
    final address = TextEditingController(text: email);
    final password = TextEditingController();
    final request = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Cloud account'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'Sign in once to automatically sync this app on future launches.'),
                  const SizedBox(height: 12),
                  TextField(
                      controller: address,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(
                          labelText: 'Email address',
                          hintText: 'name@example.com')),
                  TextField(
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password'))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, {
                            'action': 'create',
                            'email': address.text.trim(),
                            'password': password.text
                          }),
                      child: const Text('Create account')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, {
                            'action': 'signin',
                            'email': address.text.trim(),
                            'password': password.text
                          }),
                      child: const Text('Sign in'))
                ]));
    final isCreatingAccount = request?['action'] == 'create';
    final minimumPasswordLength = isCreatingAccount ? 12 : 6;
    if (request == null ||
        request['email']!.isEmpty ||
        request['password']!.length < minimumPasswordLength) {
      if (request != null && mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isCreatingAccount
                ? 'Use at least 12 characters for a new password.'
                : 'Enter an email and a password with at least 6 characters.')));
      return;
    }
    try {
      if (request['action'] == 'create') {
        final response = await _cloud.auth.signUp(
            email: request['email']!,
            password: request['password']!,
            emailRedirectTo: 'io.supabase.myexpensia://login-callback');
        if (response.session == null) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'Account created. Confirm the email once, then sign in with your password.')));
          return;
        }
      } else {
        await _cloud.auth.signInWithPassword(
            email: request['email']!, password: request['password']!);
      }
      await syncCloud();
    } on AuthException catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error.statusCode == '429'
                ? 'Email limit reached. Please try again in one hour.'
                : error.message)));
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to connect to cloud sync.')));
    }
  }

  Future<void> unlock() async {
    try {
      if (!await _auth.isDeviceSupported()) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content:
                  Text('Biometric unlock is not available on this device.')));
        return;
      }
      final allowed = await _auth.authenticate(
          localizedReason: 'Unlock My Expensia',
          biometricOnly: true,
          persistAcrossBackgrounding: true);
      if (allowed && mounted) setState(() => locked = false);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Unable to verify biometrics on this device.')));
    }
  }

  Future<bool> confirmCapWarning(Tx tx) async {
    if (tx.inflow) return true;
    final cap = current.categoryCaps[tx.category];
    if (cap == null || cap <= 0) return true;
    final now = tx.createdAt;
    final spent = current.transactions
        .where((item) =>
            !item.inflow &&
            item.category == tx.category &&
            item.createdAt.year == now.year &&
            item.createdAt.month == now.month)
        .fold<double>(tx.amount, (sum, item) => sum + item.amount);
    if (spent < cap * .9) return true;
    final ratio = spent / cap;
    final over = spent > cap;
    return await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
                    title: Text(over
                        ? 'Category cap exceeded'
                        : 'Category cap warning'),
                    content: Text(
                        '${tx.category} will be ${(ratio * 100).toStringAsFixed(1)}% of its monthly cap.\n\n${current.currency.symbol} ${spent.toStringAsFixed(2)} of ${current.currency.symbol} ${cap.toStringAsFixed(2)}'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Save anyway'))
                    ])) ??
        false;
  }

  Future<void> addTx(bool inflow) async {
    final desc = TextEditingController();
    final amount = TextEditingController();
    var category = categories.first;
    final tx = await showDialog<Tx>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialog) => AlertDialog(
                    title: Text(inflow ? 'Add inflow' : 'Add outflow'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: desc,
                          autofocus: true,
                          decoration: const InputDecoration(
                              labelText: 'Description',
                              hintText: 'e.g. Grocery shopping')),
                      const SizedBox(height: 10),
                      TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText: 'Amount',
                              prefixText: '${current.currency.symbol} ')),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                          initialValue: category,
                          decoration:
                              const InputDecoration(labelText: 'Category'),
                          items: categories
                              .map((x) => DropdownMenuItem(
                                  value: x,
                                  child: Row(children: [
                                    Icon(_categoryIcon(x, categoryIcons),
                                        size: 18),
                                    const SizedBox(width: 8),
                                    Text(x)
                                  ])))
                              .toList(),
                          onChanged: (v) => setDialog(() => category = v!))
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(
                              ctx,
                              Tx(
                                  id: DateTime.now()
                                      .microsecondsSinceEpoch
                                      .toString(),
                                  description: desc.text.trim(),
                                  category: category,
                                  amount: double.tryParse(
                                          amount.text.replaceAll(',', '')) ??
                                      0,
                                  inflow: inflow,
                                  createdAt: DateTime.now())),
                          child: const Text('Save'))
                    ])));
    if (tx != null &&
        tx.description.isNotEmpty &&
        tx.amount > 0 &&
        await confirmCapWarning(tx)) {
      setState(() => current.transactions.insert(0, tx));
      save();
    }
  }

  Future<void> showDetails(Tx tx) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
              title: Text(tx.inflow ? 'Inflow details' : 'Outflow details'),
              content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tx.description,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Text('Portfolio: ${current.name}'),
                    Text('Category: ${tx.category}'),
                    Text(
                        'Amount: ${current.currency.symbol} ${tx.amount.toStringAsFixed(2)}'),
                    Text('Date: ${_shortDateTime(tx.createdAt)}'),
                    Text('Day: ${_dayName(tx.createdAt)}')
                  ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'))
              ]));
  Future<void> settings() async {
    final r = await Navigator.push<_SettingsData>(
        context,
        MaterialPageRoute(
            builder: (_) => Settings(
                data: _SettingsData(
                    portfolios: portfolios,
                    selected: selected,
                    name: profileName,
                    email: email,
                    categories: categories,
                    categoryIcons: categoryIcons,
                    monthlyPlans: monthlyPlans,
                    biometricEnabled: biometricEnabled),
                cloudSignedIn: _cloud.auth.currentUser != null,
                onCloudAccount: connectCloud)));
    if (r != null) {
      setState(() {
        portfolios = r.portfolios;
        selected = r.selected;
        profileName = r.name;
        email = r.email;
        categories = r.categories;
        categoryIcons = r.categoryIcons;
        monthlyPlans = r.monthlyPlans;
        biometricEnabled = r.biometricEnabled;
      });
      save();
    }
  }

  void createPlanTransaction(MonthlyPlan plan) {
    final source = portfolios.firstWhere((item) => item.id == plan.portfolioId);
    final now = DateTime.now();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final transferId = 'transfer_${now.microsecondsSinceEpoch}';
    if (plan.lastCreatedMonth == month) return;
    setState(() {
      source.transactions.insert(
          0,
          Tx(
              id: '${now.microsecondsSinceEpoch}_out',
              description: plan.description,
              category: plan.category,
              amount: plan.amount,
              inflow: false,
              createdAt: now,
              transferId: plan.savingsTransfer ? transferId : null));
      if (plan.savingsTransfer &&
          plan.destinationPortfolioId != null &&
          plan.destinationPortfolioId != source.id) {
        portfolios
            .firstWhere((item) => item.id == plan.destinationPortfolioId)
            .transactions
            .insert(
                0,
                Tx(
                    id: '${now.microsecondsSinceEpoch}_in',
                    description: plan.description,
                    category: plan.category,
                    amount: plan.amount,
                    inflow: true,
                    createdAt: now,
                    transferId: transferId));
      }
      final index = monthlyPlans.indexWhere((item) => item.id == plan.id);
      if (index >= 0)
        monthlyPlans[index] = MonthlyPlan(
            id: plan.id,
            description: plan.description,
            category: plan.category,
            amount: plan.amount,
            dueDay: plan.dueDay,
            portfolioId: plan.portfolioId,
            savingsTransfer: plan.savingsTransfer,
            destinationPortfolioId: plan.destinationPortfolioId,
            recurring: plan.recurring,
            lastCreatedMonth: month);
    });
    save();
  }

  Future<void> openPlanTransactions() => Navigator.push<void>(
      context,
      MaterialPageRoute(
          builder: (_) => PlanTransactionsPage(
              plans: monthlyPlans,
              portfolios: portfolios,
              icons: categoryIcons,
              onCreate: createPlanTransaction)));
  @override
  Widget build(BuildContext c) {
    if (loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (locked)
      return Scaffold(
          body: Center(
              child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.lock_outline, size: 56),
                    const SizedBox(height: 16),
                    Text('My Expensia is locked',
                        style: Theme.of(c).textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    const Text(
                        'Use Face ID or your device biometric to unlock.'),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                        onPressed: unlock,
                        icon: const Icon(Icons.fingerprint),
                        label: const Text('Unlock'))
                  ]))));
    final signedIn = _cloud.auth.currentUser != null;
    return Scaffold(
        appBar: AppBar(
            title: Text(profileName.isEmpty
                ? 'My Expensia'
                : 'My Expensia - $profileName'),
            actions: [
              IconButton(
                  tooltip: signedIn ? 'Cloud account connected' : 'Cloud login',
                  onPressed: connectCloud,
                  icon: Icon(signedIn ? Icons.cloud_done : Icons.cloud_outlined,
                      color: signedIn ? Colors.blue.shade700 : null)),
              IconButton(
                  tooltip: 'Monthly plans',
                  onPressed: openPlanTransactions,
                  icon: const Icon(Icons.calendar_month_outlined)),
              IconButton(onPressed: settings, icon: const Icon(Icons.settings))
            ]),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          DropdownButtonFormField<String>(
              initialValue: selected,
              decoration: const InputDecoration(labelText: 'Active portfolio'),
              items: portfolios
                  .map(
                      (p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                  .toList(),
              onChanged: (v) {
                setState(() => selected = v!);
                save();
              }),
          const SizedBox(height: 20),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(children: [
                    Text(current.name, style: Theme.of(c).textTheme.titleLarge),
                    Text(
                        '${current.currency.symbol} ${current.balance.toStringAsFixed(2)}',
                        style: Theme.of(c).textTheme.displaySmall)
                  ]))),
          const SizedBox(height: 14),
          _ReportGraph(
              inflow: total(true),
              outflow: total(false),
              currency: current.currency,
              onTap: () => Navigator.push(
                  c,
                  MaterialPageRoute(
                      builder: (_) => CategoryReportPage(
                          portfolio: current, icons: categoryIcons)))),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: FilledButton.icon(
                    onPressed: () => addTx(true),
                    icon: const Icon(Icons.add),
                    label: const Text('Add inflow'))),
            const SizedBox(width: 10),
            Expanded(
                child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade700),
                    onPressed: () => addTx(false),
                    icon: const Icon(Icons.remove),
                    label: const Text('Add outflow')))
          ]),
          const SizedBox(height: 24),
          Text('Transactions', style: Theme.of(c).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (current.transactions.isEmpty)
            const Padding(
                padding: EdgeInsets.all(20),
                child: const Text('No transactions yet.')),
          ...current.transactions.map((t) => Card(
              child: ListTile(
                  onTap: () => showDetails(t),
                  leading: CircleAvatar(
                      child: Icon(_categoryIcon(t.category, categoryIcons))),
                  title: Text(t.description),
                  subtitle:
                      Text('${t.category} - ${_shortDateTime(t.createdAt)}'),
                  trailing: Text(
                      '${t.inflow ? '+' : '-'}${current.currency.symbol} ${t.amount.toStringAsFixed(2)}',
                      style: TextStyle(
                          color: t.inflow ? Colors.teal : Colors.red,
                          fontWeight: FontWeight.bold)))))
        ]));
  }
}

class _ReportGraph extends StatelessWidget {
  const _ReportGraph(
      {required this.inflow,
      required this.outflow,
      required this.currency,
      required this.onTap});
  final double inflow, outflow;
  final Currency currency;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final max = (inflow > outflow ? inflow : outflow);
    return Card(
        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(children: [
                        Text('Portfolio report',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                        Spacer(),
                        Icon(Icons.chevron_right)
                      ]),
                      const SizedBox(height: 4),
                      const Text('Tap for category details'),
                      const SizedBox(height: 14),
                      _Bar(
                          label: 'Inflow',
                          amount: inflow,
                          max: max,
                          color: Colors.teal,
                          currency: currency),
                      const SizedBox(height: 12),
                      _Bar(
                          label: 'Outflow',
                          amount: outflow,
                          max: max,
                          color: Colors.red,
                          currency: currency)
                    ]))));
  }
}

class _Bar extends StatelessWidget {
  const _Bar(
      {required this.label,
      required this.amount,
      required this.max,
      required this.color,
      required this.currency});
  final String label;
  final double amount, max;
  final Color color;
  final Currency currency;
  @override
  Widget build(BuildContext context) {
    final factor = max == 0 ? 0.0 : amount / max;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(label),
        const Spacer(),
        Text('${currency.symbol} ${amount.toStringAsFixed(2)}')
      ]),
      const SizedBox(height: 5),
      LayoutBuilder(
          builder: (context, size) => Container(
              height: 14,
              width: size.maxWidth,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(8)),
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  height: 14,
                  width: size.maxWidth * factor,
                  decoration: BoxDecoration(
                      color: color, borderRadius: BorderRadius.circular(8)))))
    ]);
  }
}

class CategoryReportPage extends StatelessWidget {
  const CategoryReportPage(
      {super.key, required this.portfolio, required this.icons});
  final Portfolio portfolio;
  final Map<String, int> icons;
  @override
  Widget build(BuildContext context) {
    final totals = <String, double>{};
    for (final tx in portfolio.transactions.where((tx) => !tx.inflow)) {
      totals.update(tx.category, (amount) => amount + tx.amount,
          ifAbsent: () => tx.amount);
    }
    final entries = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<double>(0, (sum, entry) => sum + entry.value);
    final now = DateTime.now();
    return Scaffold(
        appBar: AppBar(title: Text('${portfolio.name} report')),
        body: entries.isEmpty
            ? const Center(child: Text('No outflow transactions yet.'))
            : ListView(padding: const EdgeInsets.all(20), children: [
                Text('Category outflow',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text('All recorded outflows in ${portfolio.name}'),
                const SizedBox(height: 16),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(children: [
                          const Icon(Icons.arrow_downward, color: Colors.red),
                          const SizedBox(width: 10),
                          const Text('Total outflow'),
                          const Spacer(),
                          Text(
                              '${portfolio.currency.symbol} ${total.toStringAsFixed(2)}',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold))
                        ]))),
                const SizedBox(height: 12),
                ...entries.map((entry) {
                  final portion = total == 0 ? 0.0 : entry.value / total;
                  final monthlyUsed = portfolio.transactions
                      .where((tx) =>
                          !tx.inflow &&
                          tx.category == entry.key &&
                          tx.createdAt.year == now.year &&
                          tx.createdAt.month == now.month)
                      .fold<double>(0, (sum, tx) => sum + tx.amount);
                  final cap = portfolio.categoryCaps[entry.key];
                  final capRatio = cap == null ? 0.0 : monthlyUsed / cap;
                  final barValue = cap == null
                      ? portion
                      : capRatio.clamp(0.0, 1.0).toDouble();
                  final ratioForColor = cap == null ? portion : capRatio;
                  final barColor = ratioForColor < 0.9
                      ? Colors.blue.shade700
                      : Colors.red.shade700;
                  return Card(
                      child: InkWell(
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => CategoryTransactionsPage(
                                      portfolio: portfolio,
                                      category: entry.key,
                                      icons: icons))),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      CircleAvatar(
                                          child: Icon(
                                              _categoryIcon(entry.key, icons))),
                                      const SizedBox(width: 12),
                                      Expanded(
                                          child: Text(entry.key,
                                              style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight:
                                                      FontWeight.w600))),
                                      Text(
                                          '${portfolio.currency.symbol} ${entry.value.toStringAsFixed(2)}',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold)),
                                      const SizedBox(width: 4),
                                      const Icon(Icons.chevron_right)
                                    ]),
                                    const SizedBox(height: 12),
                                    LinearProgressIndicator(
                                        value: barValue,
                                        minHeight: 9,
                                        borderRadius: BorderRadius.circular(8),
                                        color: barColor,
                                        backgroundColor:
                                            barColor.withValues(alpha: 0.15)),
                                    const SizedBox(height: 6),
                                    Text(
                                        cap == null
                                            ? '${(portion * 100).toStringAsFixed(1)}% of outflow - tap for transactions'
                                            : 'This month: ${portfolio.currency.symbol} ${monthlyUsed.toStringAsFixed(2)} / ${portfolio.currency.symbol} ${cap.toStringAsFixed(2)} (${(monthlyUsed / cap * 100).toStringAsFixed(1)}% used) - tap for transactions',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall)
                                  ]))));
                })
              ]));
  }
}

class CategoryTransactionsPage extends StatelessWidget {
  const CategoryTransactionsPage(
      {super.key,
      required this.portfolio,
      required this.category,
      required this.icons});
  final Portfolio portfolio;
  final String category;
  final Map<String, int> icons;
  void details(BuildContext context, Tx tx) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
              title: const Text('Outflow details'),
              content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tx.description,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Text('Portfolio: ${portfolio.name}'),
                    Text('Category: ${tx.category}'),
                    Text(
                        'Amount: ${portfolio.currency.symbol} ${tx.amount.toStringAsFixed(2)}'),
                    Text('Date: ${_shortDateTime(tx.createdAt)}'),
                    Text('Day: ${_dayName(tx.createdAt)}')
                  ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'))
              ]));
  @override
  Widget build(BuildContext context) {
    final transactions = portfolio.transactions
        .where((tx) => !tx.inflow && tx.category == category)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Scaffold(
        appBar: AppBar(title: Text(category)),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          Text('Transaction history',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
              '${transactions.length} outflow transaction${transactions.length == 1 ? '' : 's'}'),
          const SizedBox(height: 14),
          ...transactions.map((tx) => Card(
              child: ListTile(
                  onTap: () => details(context, tx),
                  leading:
                      CircleAvatar(child: Icon(_categoryIcon(category, icons))),
                  title: Text(tx.description),
                  subtitle: Text(_shortDateTime(tx.createdAt)),
                  trailing: Text(
                      '-${portfolio.currency.symbol} ${tx.amount.toStringAsFixed(2)}',
                      style: const TextStyle(
                          color: Colors.red, fontWeight: FontWeight.bold)))))
        ]));
  }
}

class _SettingsData {
  const _SettingsData(
      {required this.portfolios,
      required this.selected,
      required this.name,
      required this.email,
      required this.categories,
      required this.categoryIcons,
      required this.monthlyPlans,
      required this.biometricEnabled});
  final List<Portfolio> portfolios;
  final String selected, name, email;
  final List<String> categories;
  final Map<String, int> categoryIcons;
  final List<MonthlyPlan> monthlyPlans;
  final bool biometricEnabled;
}

class Settings extends StatefulWidget {
  const Settings(
      {super.key,
      required this.data,
      required this.cloudSignedIn,
      required this.onCloudAccount});
  final _SettingsData data;
  final bool cloudSignedIn;
  final Future<void> Function() onCloudAccount;
  @override
  State<Settings> createState() => _SettingsState();
}

class _SettingsState extends State<Settings> {
  late List<Portfolio> portfolios;
  late String selected;
  late TextEditingController name, email;
  late List<String> categories;
  late Map<String, int> categoryIcons;
  late List<MonthlyPlan> monthlyPlans;
  late bool biometricEnabled;
  @override
  void initState() {
    super.initState();
    portfolios = widget.data.portfolios
        .map((p) => Portfolio(
            id: p.id,
            name: p.name,
            opening: p.opening,
            currency: p.currency,
            transactions: [...p.transactions],
            categoryCaps: {...p.categoryCaps}))
        .toList();
    selected = widget.data.selected;
    categories = [...widget.data.categories];
    categoryIcons = {...widget.data.categoryIcons};
    monthlyPlans = [...widget.data.monthlyPlans];
    biometricEnabled = widget.data.biometricEnabled;
    name = TextEditingController(text: widget.data.name);
    email = TextEditingController(text: widget.data.email);
  }

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    super.dispose();
  }

  Portfolio get current => portfolios.firstWhere((p) => p.id == selected);
  Future<void> toggleBiometric(bool value) async {
    if (value) {
      try {
        final auth = LocalAuthentication();
        if (!await auth.isDeviceSupported()) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'Biometric authentication is not available on this device.')));
          return;
        }
        final confirmed = await auth.authenticate(
            localizedReason: 'Confirm to enable biometric lock',
            biometricOnly: true,
            persistAcrossBackgrounding: true);
        if (!confirmed) return;
      } catch (_) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Unable to enable biometric lock.')));
        return;
      }
    }
    if (mounted) setState(() => biometricEnabled = value);
  }

  Future<void> addPortfolio() async {
    final n = TextEditingController();
    var currency = current.currency;
    final r = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                    title: const Text('Add portfolio'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: n,
                          decoration: const InputDecoration(
                              labelText: 'Portfolio name')),
                      DropdownButtonFormField<Currency>(
                          initialValue: currency,
                          items: Currency.values
                              .map((x) => DropdownMenuItem(
                                  value: x, child: Text(x.nameLabel)))
                              .toList(),
                          onChanged: (v) => setD(() => currency = v!))
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, n.text),
                          child: const Text('Add'))
                    ])));
    if (r != null && r.trim().isNotEmpty)
      setState(() {
        final p = Portfolio(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: r.trim(),
            currency: currency);
        portfolios.add(p);
        selected = p.id;
      });
  }

  Future<void> resetPortfolio(Portfolio portfolio) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text('Reset ${portfolio.name}?'),
                content: const Text(
                    'This permanently clears all transactions and resets the portfolio amount to zero. Category caps and portfolio settings are kept.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade700),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Reset portfolio'))
                ]));
    if (confirmed != true) return;
    setState(() {
      portfolio.transactions.clear();
      portfolio.opening = 0;
      monthlyPlans = monthlyPlans
          .map((plan) => plan.portfolioId != portfolio.id
              ? plan
              : MonthlyPlan(
                  id: plan.id,
                  description: plan.description,
                  category: plan.category,
                  amount: plan.amount,
                  dueDay: plan.dueDay,
                  portfolioId: plan.portfolioId,
                  savingsTransfer: plan.savingsTransfer,
                  destinationPortfolioId: plan.destinationPortfolioId,
                  recurring: plan.recurring))
          .toList();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${portfolio.name} has been reset.')));
    }
  }

  Future<void> addCategory() async {
    final c = TextEditingController();
    var icon = Icons.sell_outlined;
    final r = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                    title: const Text('Add category'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: c,
                          decoration: const InputDecoration(
                              labelText: 'Category name')),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<int>(
                          initialValue: icon.codePoint,
                          decoration:
                              const InputDecoration(labelText: 'Built-in icon'),
                          items: [
                            Icons.sell_outlined,
                            Icons.home_outlined,
                            Icons.favorite_outline,
                            Icons.star_outline,
                            Icons.work_outline,
                            Icons.flight_outlined,
                            Icons.coffee_outlined,
                            Icons.sports_soccer_outlined
                          ]
                              .map((i) => DropdownMenuItem(
                                  value: i.codePoint, child: Icon(i)))
                              .toList(),
                          onChanged: (v) => setD(() => icon = _iconForCode(v!)))
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, c.text),
                          child: const Text('Add'))
                    ])));
    if (r != null && r.trim().isNotEmpty && !categories.contains(r.trim()))
      setState(() {
        categories.add(r.trim());
        categoryIcons[r.trim()] = icon.codePoint;
      });
  }

  Future<void> openCategories() async {
    final r = await Navigator.push<CategoryData>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                CategoriesPage(data: CategoryData(categories, categoryIcons))));
    if (r != null)
      setState(() {
        categories = r.categories;
        categoryIcons = r.icons;
      });
  }

  Future<void> openHistory() async {
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => AllTransactionsPage(
                portfolios: portfolios,
                icons: categoryIcons,
                plans: monthlyPlans,
                categories: categories)));
    setState(() {});
  }

  Future<void> openPlans() async {
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => MonthlyPlansPage(
                plans: monthlyPlans,
                portfolios: portfolios,
                categories: categories,
                icons: categoryIcons)));
    setState(() {});
  }

  Future<void> openCaps() async {
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => MonthlyCapsPage(
                portfolios: portfolios,
                initialSelected: selected,
                categories: categories,
                icons: categoryIcons)));
    setState(() {});
  }

  void done() => Navigator.pop(
      context,
      _SettingsData(
          portfolios: portfolios,
          selected: selected,
          name: name.text.trim(),
          email: email.text.trim(),
          categories: categories,
          categoryIcons: categoryIcons,
          monthlyPlans: monthlyPlans,
          biometricEnabled: biometricEnabled));
  @override
  Widget build(BuildContext c) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) done();
      },
      child: Scaffold(
          appBar: AppBar(title: const Text('Settings'), actions: [
            TextButton(onPressed: done, child: const Text('Save'))
          ]),
          body: ListView(padding: const EdgeInsets.all(20), children: [
            const Text('Account',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name')),
            TextField(
                controller: email,
                decoration: const InputDecoration(labelText: 'Email')),
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.cloud_outlined,
                    color: widget.cloudSignedIn ? Colors.blue.shade700 : null),
                title: Text(widget.cloudSignedIn
                    ? 'Cloud account connected'
                    : 'Cloud login'),
                subtitle: Text(widget.cloudSignedIn
                    ? 'Your data syncs with your signed-in account.'
                    : 'Sign in or create an account to sync your data.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: widget.onCloudAccount),
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.fingerprint),
                title: const Text('Face ID / biometric lock'),
                subtitle: const Text('Lock the app when it leaves the screen.'),
                value: biometricEnabled,
                onChanged: toggleBiometric),
            const SizedBox(height: 20),
            const Text('Portfolios',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ...portfolios.map((p) => ListTile(
                onTap: () => setState(() => selected = p.id),
                leading: Icon(p.id == selected
                    ? Icons.check_circle
                    : Icons.account_balance_wallet_outlined),
                title: Text(p.name),
                subtitle: Text(p.currency.nameLabel),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'Reset portfolio data',
                      onPressed: () => resetPortfolio(p),
                      icon: const Icon(Icons.restart_alt_outlined)),
                  if (portfolios.length > 1)
                    IconButton(
                        onPressed: () => setState(() {
                              portfolios.remove(p);
                              if (selected == p.id)
                                selected = portfolios.first.id;
                            }),
                        icon: const Icon(Icons.delete_outline))
                ]))),
            FilledButton.icon(
                onPressed: addPortfolio,
                icon: const Icon(Icons.add),
                label: const Text('Add portfolio')),
            const SizedBox(height: 20),
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('Transaction history'),
                subtitle: const Text('View, edit, and delete all transactions'),
                trailing: const Icon(Icons.chevron_right),
                onTap: openHistory),
            const SizedBox(height: 8),
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_month_outlined),
                title: const Text('Monthly plans'),
                subtitle: Text('${monthlyPlans.length} recurring plans'),
                trailing: const Icon(Icons.chevron_right),
                onTap: openPlans),
            const SizedBox(height: 8),
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.pie_chart_outline),
                title: const Text('Monthly category caps'),
                subtitle: Text(
                    'Caps for ${current.name}; reset on the 1st each month'),
                trailing: const Icon(Icons.chevron_right),
                onTap: openCaps),
            const SizedBox(height: 8),
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.category_outlined),
                title: const Text('Categories'),
                subtitle: Text(' categories'),
                trailing: const Icon(Icons.chevron_right),
                onTap: openCategories)
          ])));
}

class AllTransactionsPage extends StatefulWidget {
  const AllTransactionsPage(
      {super.key,
      required this.portfolios,
      required this.icons,
      required this.plans,
      required this.categories});
  final List<Portfolio> portfolios;
  final Map<String, int> icons;
  final List<MonthlyPlan> plans;
  final List<String> categories;
  @override
  State<AllTransactionsPage> createState() => _AllTransactionsPageState();
}

class _AllTransactionsPageState extends State<AllTransactionsPage> {
  List<(Portfolio, Tx)> get entries {
    final result = <(Portfolio, Tx)>[];
    for (final portfolio in widget.portfolios) {
      for (final tx in portfolio.transactions) {
        result.add((portfolio, tx));
      }
    }
    result.sort((a, b) => b.$2.createdAt.compareTo(a.$2.createdAt));
    return result;
  }

  Future<void> edit(Portfolio portfolio, Tx tx) async {
    final description = TextEditingController(text: tx.description);
    final amount = TextEditingController(text: tx.amount.toStringAsFixed(2));
    var category = tx.category;
    final updated = await showDialog<Tx>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialog) => AlertDialog(
                    title: const Text('Edit transaction'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: description,
                          autofocus: true,
                          decoration:
                              const InputDecoration(labelText: 'Description')),
                      const SizedBox(height: 10),
                      TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText: 'Amount',
                              prefixText: '${portfolio.currency.symbol} ')),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                          initialValue: category,
                          decoration:
                              const InputDecoration(labelText: 'Category'),
                          items: widget.categories
                              .map((item) => DropdownMenuItem(
                                  value: item, child: Text(item)))
                              .toList(),
                          onChanged: (value) =>
                              setDialog(() => category = value!))
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(
                              ctx,
                              Tx(
                                  id: tx.id,
                                  description: description.text.trim(),
                                  category: category,
                                  amount: double.tryParse(
                                          amount.text.replaceAll(',', '')) ??
                                      0,
                                  inflow: tx.inflow,
                                  createdAt: tx.createdAt,
                                  transferId: tx.transferId)),
                          child: const Text('Save'))
                    ])));
    if (updated == null || updated.description.isEmpty || updated.amount <= 0)
      return;
    setState(() {
      for (final item in widget.portfolios) {
        for (var index = 0; index < item.transactions.length; index++) {
          final entry = item.transactions[index];
          final linked =
              tx.transferId != null && entry.transferId == tx.transferId;
          if ((item.id == portfolio.id && entry.id == tx.id) || linked) {
            item.transactions[index] = Tx(
                id: entry.id,
                description: updated.description,
                category: updated.category,
                amount: updated.amount,
                inflow: entry.inflow,
                createdAt: updated.createdAt,
                transferId: entry.transferId);
          }
        }
      }
    });
    if (mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Transaction updated.')));
  }

  Future<void> remove(Portfolio portfolio, Tx tx) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Delete transaction?'),
                content: const Text(
                    'This reverses the amount in the portfolio balance. Linked savings-transfer entries are deleted together.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade700),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete'))
                ]));
    if (confirmed != true) return;
    final now = DateTime.now();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    setState(() {
      if (tx.transferId != null) {
        for (final item in widget.portfolios) {
          item.transactions
              .removeWhere((entry) => entry.transferId == tx.transferId);
        }
      } else {
        portfolio.transactions.removeWhere((entry) => entry.id == tx.id);
        final pairedId = tx.id.endsWith('_out')
            ? '${tx.id.substring(0, tx.id.length - 4)}_in'
            : tx.id.endsWith('_in')
                ? '${tx.id.substring(0, tx.id.length - 3)}_out'
                : null;
        if (pairedId != null) {
          for (final item in widget.portfolios) {
            item.transactions.removeWhere((entry) => entry.id == pairedId);
          }
        }
      }
      for (var index = 0; index < widget.plans.length; index++) {
        final plan = widget.plans[index];
        if (plan.lastCreatedMonth == month &&
            plan.description == tx.description &&
            plan.amount == tx.amount) {
          widget.plans[index] = MonthlyPlan(
              id: plan.id,
              description: plan.description,
              category: plan.category,
              amount: plan.amount,
              dueDay: plan.dueDay,
              portfolioId: plan.portfolioId,
              savingsTransfer: plan.savingsTransfer,
              destinationPortfolioId: plan.destinationPortfolioId,
              recurring: plan.recurring);
        }
      }
    });
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Transaction deleted and balance reversed.')));
  }

  @override
  Widget build(BuildContext context) {
    final data = entries;
    return Scaffold(
        appBar: AppBar(title: const Text('Transaction history')),
        body: data.isEmpty
            ? const Center(child: Text('No transactions yet.'))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: data.map((entry) {
                  final portfolio = entry.$1;
                  final tx = entry.$2;
                  return Card(
                      child: ListTile(
                          onTap: () => edit(portfolio, tx),
                          leading: CircleAvatar(
                              child: Icon(
                                  _categoryIcon(tx.category, widget.icons))),
                          title: Text(tx.description),
                          subtitle: Text(
                              '${portfolio.name} - ${tx.category}\n${_shortDateTime(tx.createdAt)}'),
                          isThreeLine: true,
                          trailing:
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(
                                '${tx.inflow ? '+' : '-'}${portfolio.currency.symbol} ${tx.amount.toStringAsFixed(2)}',
                                style: TextStyle(
                                    color: tx.inflow ? Colors.teal : Colors.red,
                                    fontWeight: FontWeight.bold)),
                            IconButton(
                                tooltip: 'Delete and reverse',
                                onPressed: () => remove(portfolio, tx),
                                icon: const Icon(Icons.delete_outline))
                          ])));
                }).toList()));
  }
}

class PlanTransactionsPage extends StatefulWidget {
  const PlanTransactionsPage(
      {super.key,
      required this.plans,
      required this.portfolios,
      required this.icons,
      required this.onCreate});
  final List<MonthlyPlan> plans;
  final List<Portfolio> portfolios;
  final Map<String, int> icons;
  final void Function(MonthlyPlan) onCreate;
  @override
  State<PlanTransactionsPage> createState() => _PlanTransactionsPageState();
}

class _PlanTransactionsPageState extends State<PlanTransactionsPage> {
  Portfolio portfolio(String id) =>
      widget.portfolios.firstWhere((item) => item.id == id,
          orElse: () => widget.portfolios.first);
  bool createdThisMonth(MonthlyPlan plan, DateTime now) {
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final source = portfolio(plan.portfolioId);
    return plan.lastCreatedMonth == month ||
        source.transactions.any((tx) =>
            !tx.inflow &&
            tx.description == plan.description &&
            tx.amount == plan.amount &&
            tx.createdAt.year == now.year &&
            tx.createdAt.month == now.month);
  }

  void create(MonthlyPlan plan) {
    widget.onCreate(plan);
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${plan.description} created.')));
  }

  @override
  Widget build(BuildContext context) {
    final ordered = [...widget.plans]
      ..sort((a, b) => a.dueDay.compareTo(b.dueDay));
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Monthly plans')),
      body: ordered.isEmpty
          ? const Center(child: Text('No monthly plans yet.'))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('Create plan transactions',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                const Text(
                    'Use Create now when you want to record a planned expense or savings transfer.'),
                const SizedBox(height: 14),
                ...ordered.map((plan) {
                  final source = portfolio(plan.portfolioId);
                  final destination = plan.destinationPortfolioId == null
                      ? null
                      : portfolio(plan.destinationPortfolioId!);
                  final isCreated = createdThisMonth(plan, now);
                  return Card(
                      child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            CircleAvatar(
                                child: Icon(plan.savingsTransfer
                                    ? Icons.savings_outlined
                                    : _categoryIcon(
                                        plan.category, widget.icons))),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Text(plan.description,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold))),
                            Text(
                                '${source.currency.symbol} ${plan.amount.toStringAsFixed(0)}'),
                          ]),
                          const SizedBox(height: 8),
                          Text(
                              '${plan.savingsTransfer ? 'Transfer' : 'Expense'} from ${source.name}${destination == null ? '' : ' to ${destination.name}'} - due day ${plan.dueDay}'),
                          const SizedBox(height: 10),
                          Align(
                              alignment: Alignment.centerRight,
                              child: FilledButton.icon(
                                onPressed:
                                    isCreated ? null : () => create(plan),
                                icon: Icon(
                                    isCreated ? Icons.check : Icons.play_arrow),
                                label: Text(isCreated
                                    ? 'Created this month'
                                    : 'Create now'),
                              )),
                        ]),
                  ));
                }),
              ],
            ),
    );
  }
}

class MonthlyPlansPage extends StatefulWidget {
  const MonthlyPlansPage(
      {super.key,
      required this.plans,
      required this.portfolios,
      required this.categories,
      required this.icons});
  final List<MonthlyPlan> plans;
  final List<Portfolio> portfolios;
  final List<String> categories;
  final Map<String, int> icons;
  @override
  State<MonthlyPlansPage> createState() => _MonthlyPlansPageState();
}

class _MonthlyPlansPageState extends State<MonthlyPlansPage> {
  Portfolio portfolio(String id) =>
      widget.portfolios.firstWhere((item) => item.id == id,
          orElse: () => widget.portfolios.first);
  Future<void> edit([MonthlyPlan? existing]) async {
    final description =
        TextEditingController(text: existing?.description ?? '');
    final amount =
        TextEditingController(text: existing?.amount.toStringAsFixed(2) ?? '');
    final dueDay =
        TextEditingController(text: (existing?.dueDay ?? 1).toString());
    var source = existing?.portfolioId ?? widget.portfolios.first.id;
    var category = existing?.category ?? widget.categories.first;
    var transfer = existing?.savingsTransfer ?? false;
    var destination = existing?.destinationPortfolioId ??
        widget.portfolios
            .firstWhere((item) => item.name == 'Savings / Reserves',
                orElse: () => widget.portfolios.first)
            .id;
    var recurring = existing?.recurring ?? true;
    final saved = await showDialog<MonthlyPlan>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialog) => AlertDialog(
                    title: Text(existing == null
                        ? 'Add monthly plan'
                        : 'Edit monthly plan'),
                    content: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: description,
                          autofocus: true,
                          decoration:
                              const InputDecoration(labelText: 'Description')),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                          initialValue: source,
                          decoration: const InputDecoration(
                              labelText: 'Source portfolio'),
                          items: widget.portfolios
                              .map((item) => DropdownMenuItem(
                                  value: item.id, child: Text(item.name)))
                              .toList(),
                          onChanged: (value) =>
                              setDialog(() => source = value!)),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                          initialValue: category,
                          decoration:
                              const InputDecoration(labelText: 'Category'),
                          items: widget.categories
                              .map((item) => DropdownMenuItem(
                                  value: item, child: Text(item)))
                              .toList(),
                          onChanged: (value) =>
                              setDialog(() => category = value!)),
                      const SizedBox(height: 10),
                      TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText: 'Amount',
                              prefixText:
                                  '${portfolio(source).currency.symbol} ')),
                      const SizedBox(height: 10),
                      TextField(
                          controller: dueDay,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Due day (1-31)')),
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Savings transfer'),
                          value: transfer,
                          onChanged: (value) =>
                              setDialog(() => transfer = value)),
                      if (transfer)
                        DropdownButtonFormField<String>(
                            initialValue: destination,
                            decoration: const InputDecoration(
                                labelText: 'Destination portfolio'),
                            items: widget.portfolios
                                .map((item) => DropdownMenuItem(
                                    value: item.id, child: Text(item.name)))
                                .toList(),
                            onChanged: (value) =>
                                setDialog(() => destination = value!)),
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Recurring monthly'),
                          value: recurring,
                          onChanged: (value) =>
                              setDialog(() => recurring = value))
                    ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () {
                            final value = double.tryParse(
                                    amount.text.replaceAll(',', '')) ??
                                0;
                            final day =
                                (int.tryParse(dueDay.text) ?? 1).clamp(1, 31);
                            if (description.text.trim().isNotEmpty && value > 0)
                              Navigator.pop(
                                  ctx,
                                  MonthlyPlan(
                                      id: existing?.id ??
                                          DateTime.now()
                                              .microsecondsSinceEpoch
                                              .toString(),
                                      description: description.text.trim(),
                                      category: category,
                                      amount: value,
                                      dueDay: day,
                                      portfolioId: source,
                                      savingsTransfer: transfer,
                                      destinationPortfolioId:
                                          transfer ? destination : null,
                                      recurring: recurring,
                                      lastCreatedMonth:
                                          existing?.lastCreatedMonth));
                          },
                          child: const Text('Save'))
                    ])));
    if (saved != null)
      setState(() {
        final index = widget.plans.indexWhere((plan) => plan.id == saved.id);
        if (index < 0) {
          widget.plans.add(saved);
        } else {
          widget.plans[index] = saved;
        }
      });
  }

  @override
  Widget build(BuildContext context) {
    final plans = [...widget.plans]
      ..sort((a, b) => a.dueDay.compareTo(b.dueDay));
    return Scaffold(
        appBar: AppBar(title: const Text('Monthly plans')),
        body: plans.isEmpty
            ? const Center(child: Text('No monthly plans yet.'))
            : ListView(padding: const EdgeInsets.all(20), children: [
                Text('Recurring commitments',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                const Text(
                    'Use this page to configure plans. Create transactions from the homepage calendar.'),
                const SizedBox(height: 14),
                ...plans.map((plan) {
                  final source = portfolio(plan.portfolioId);
                  final destination = plan.destinationPortfolioId == null
                      ? null
                      : portfolio(plan.destinationPortfolioId!);
                  return Card(
                      child: ListTile(
                          onTap: () => edit(plan),
                          leading: CircleAvatar(
                              child: Icon(plan.savingsTransfer
                                  ? Icons.savings_outlined
                                  : _categoryIcon(
                                      plan.category, widget.icons))),
                          title: Text(plan.description),
                          subtitle: Text(
                              '${plan.savingsTransfer ? 'Savings transfer' : 'Expense'} - ${source.name} - due day ${plan.dueDay}${plan.recurring ? ' - monthly' : ''}${destination == null ? '' : ' to ${destination.name}'}'),
                          trailing:
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(
                                '${source.currency.symbol} ${plan.amount.toStringAsFixed(0)}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            IconButton(
                                onPressed: () => setState(() => widget.plans
                                    .removeWhere((item) => item.id == plan.id)),
                                icon: const Icon(Icons.delete_outline))
                          ])));
                })
              ]),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => edit(),
            icon: const Icon(Icons.add),
            label: const Text('Add plan')));
  }
}

class MonthlyCapsPage extends StatefulWidget {
  const MonthlyCapsPage(
      {super.key,
      required this.portfolios,
      required this.initialSelected,
      required this.categories,
      required this.icons});
  final List<Portfolio> portfolios;
  final String initialSelected;
  final List<String> categories;
  final Map<String, int> icons;
  @override
  State<MonthlyCapsPage> createState() => _MonthlyCapsPageState();
}

class _MonthlyCapsPageState extends State<MonthlyCapsPage> {
  late String selected;
  @override
  void initState() {
    super.initState();
    selected = widget.initialSelected;
  }

  Portfolio get portfolio =>
      widget.portfolios.firstWhere((item) => item.id == selected);
  Future<void> editCap(String category) async {
    final amount = TextEditingController(
        text: portfolio.categoryCaps[category]?.toStringAsFixed(2) ?? '');
    final value = await showDialog<double?>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text('$category monthly cap'),
                content: TextField(
                    controller: amount,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText: 'Monthly cap',
                        prefixText: '${portfolio.currency.symbol} ')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, -1),
                      child: const Text('Remove cap')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx,
                          double.tryParse(amount.text.replaceAll(',', ''))),
                      child: const Text('Save'))
                ]));
    if (value != null)
      setState(() {
        if (value <= 0) {
          portfolio.categoryCaps.remove(category);
        } else {
          portfolio.categoryCaps[category] = value;
        }
      });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Monthly category caps')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: const InputDecoration(labelText: 'Portfolio'),
            items: widget.portfolios
                .map((item) =>
                    DropdownMenuItem(value: item.id, child: Text(item.name)))
                .toList(),
            onChanged: (value) => setState(() => selected = value!)),
        const SizedBox(height: 20),
        Text('Monthly category caps',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
            'Caps below apply to ${portfolio.name} and reset on the 1st of every month.'),
        const SizedBox(height: 16),
        ...widget.categories.map((category) {
          final cap = portfolio.categoryCaps[category];
          return Card(
              child: ListTile(
                  onTap: () => editCap(category),
                  leading: CircleAvatar(
                      child: Icon(_categoryIcon(category, widget.icons))),
                  title: Text(category),
                  subtitle: Text(cap == null
                      ? 'No cap set'
                      : '${portfolio.currency.symbol} ${cap.toStringAsFixed(2)} per month'),
                  trailing: const Icon(Icons.edit_outlined)));
        })
      ]));
}

class CategoryData {
  const CategoryData(this.categories, this.icons);
  final List<String> categories;
  final Map<String, int> icons;
}

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key, required this.data});
  final CategoryData data;
  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  late List<String> categories;
  late Map<String, int> icons;
  @override
  void initState() {
    super.initState();
    categories = [...widget.data.categories];
    icons = {...widget.data.icons};
  }

  Future<void> add() async {
    final c = TextEditingController();
    var icon = Icons.sell_outlined;
    final r = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setD) => AlertDialog(
                    title: const Text('Add category'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: c,
                          decoration: const InputDecoration(
                              labelText: 'Category name')),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<int>(
                          initialValue: icon.codePoint,
                          decoration:
                              const InputDecoration(labelText: 'Built-in icon'),
                          items: [
                            Icons.sell_outlined,
                            Icons.home_outlined,
                            Icons.favorite_outline,
                            Icons.star_outline,
                            Icons.work_outline,
                            Icons.flight_outlined,
                            Icons.coffee_outlined,
                            Icons.sports_soccer_outlined
                          ]
                              .map((i) => DropdownMenuItem(
                                  value: i.codePoint, child: Icon(i)))
                              .toList(),
                          onChanged: (v) => setD(() => icon = _iconForCode(v!)))
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, c.text),
                          child: const Text('Add'))
                    ])));
    if (r != null && r.trim().isNotEmpty && !categories.contains(r.trim()))
      setState(() {
        categories.add(r.trim());
        icons[r.trim()] = icon.codePoint;
      });
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(
          leading: IconButton(
              onPressed: () =>
                  Navigator.pop(context, CategoryData(categories, icons)),
              icon: const Icon(Icons.arrow_back)),
          title: const Text('Categories'),
          actions: [IconButton(onPressed: add, icon: const Icon(Icons.add))]),
      body: ListView(
          children: categories
              .map((x) => ListTile(
                  leading: CircleAvatar(child: Icon(_categoryIcon(x, icons))),
                  title: Text(x),
                  trailing: categories.length > 1
                      ? IconButton(
                          onPressed: () => setState(() {
                                categories.remove(x);
                                icons.remove(x);
                              }),
                          icon: const Icon(Icons.delete_outline))
                      : null))
              .toList()),
      floatingActionButton:
          FloatingActionButton(onPressed: add, child: const Icon(Icons.add)));
}

IconData _iconForCode(int code) {
  if (code == Icons.home_outlined.codePoint) return Icons.home_outlined;
  if (code == Icons.favorite_outline.codePoint) return Icons.favorite_outline;
  if (code == Icons.star_outline.codePoint) return Icons.star_outline;
  if (code == Icons.work_outline.codePoint) return Icons.work_outline;
  if (code == Icons.flight_outlined.codePoint) return Icons.flight_outlined;
  if (code == Icons.coffee_outlined.codePoint) return Icons.coffee_outlined;
  if (code == Icons.sports_soccer_outlined.codePoint)
    return Icons.sports_soccer_outlined;
  return Icons.sell_outlined;
}

IconData _categoryIcon(String category, [Map<String, int>? custom]) {
  final code = custom?[category];
  if (code != null) return _iconForCode(code);
  switch (category.toLowerCase()) {
    case 'grocery':
      return Icons.local_grocery_store_outlined;
    case 'bills':
      return Icons.receipt_long_outlined;
    case 'shopping':
      return Icons.shopping_bag_outlined;
    case 'online shopping':
      return Icons.shopping_cart_outlined;
    case 'salary':
      return Icons.account_balance_wallet_outlined;
    case 'investment':
      return Icons.trending_up_outlined;
    case 'pets':
      return Icons.pets_outlined;
    case 'restaurant':
      return Icons.restaurant_outlined;
    case 'telecommunication':
      return Icons.phone_android_outlined;
    case 'car care':
      return Icons.directions_car_outlined;
    case 'toys and gifts':
      return Icons.redeem_outlined;
    case 'electronics':
      return Icons.devices_outlined;
    case 'personal transfer':
      return Icons.swap_horiz_outlined;
    case 'utilities':
      return Icons.electrical_services_outlined;
    case 'rent & housing':
      return Icons.home_work_outlined;
    case 'education':
      return Icons.school_outlined;
    case 'dependents':
      return Icons.family_restroom_outlined;
    case 'loans & debt':
      return Icons.account_balance_outlined;
    case 'household help':
      return Icons.cleaning_services_outlined;
    case 'other':
      return Icons.more_horiz;
    default:
      return Icons.sell_outlined;
  }
}

String _shortDateTime(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
String _dayName(DateTime date) => const <String>[
      'MON',
      'TUE',
      'WED',
      'THU',
      'FRI',
      'SAT',
      'SUN'
    ][date.weekday - 1];
