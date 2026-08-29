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

String _monthName(int month) => const [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ][month - 1];

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
    for (var id = 9000; id < 9200; id++) {
      await _notifications.cancel(id: id);
    }
    final now = tz.TZDateTime.now(tz.local);
    var notificationId = 9000;
    for (var offset = 0; offset < 3; offset++) {
      final month = DateTime(now.year, now.month + offset);
      final lastDay = DateTime(month.year, month.month + 1, 0).day;
      for (final plan in plans.where((plan) => plan.recurring)) {
        final dueDay = plan.dueDay.clamp(1, lastDay).toInt();
        final due = tz.TZDateTime(tz.local, month.year, month.month, dueDay, 9);
        final reminderDates = [due.subtract(const Duration(days: 1)), due];
        for (var index = 0; index < reminderDates.length; index++) {
          final target = reminderDates[index];
          if (!target.isAfter(now) ||
              _planCreatedInMonth(plan, portfolios, target)) continue;
          await _notifications.zonedSchedule(
              id: notificationId++,
              title: index == 0 ? 'Bill due tomorrow' : 'Bill due today',
              body: '${plan.description} - due day $dueDay',
              scheduledDate: target,
              notificationDetails: const NotificationDetails(
                  android: AndroidNotificationDetails(
                      'monthly_plan_reminders', 'Monthly plan reminders',
                      channelDescription:
                          'Due-date reminders for monthly plans',
                      importance: Importance.high,
                      priority: Priority.high)),
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle);
        }
      }
    }
  }
}

bool _planCreatedInMonth(
    MonthlyPlan plan, List<Portfolio> portfolios, DateTime date) {
  final month = '${date.year}-${date.month.toString().padLeft(2, '0')}';
  if (plan.lastCreatedMonth == month || plan.lastSkippedMonth == month) {
    return true;
  }
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

class _ActivityNotice {
  const _ActivityNotice(
      {required this.id,
      required this.title,
      required this.message,
      required this.createdAt,
      required this.icon,
      this.transaction,
      this.portfolio});
  final String id, title, message;
  final DateTime createdAt;
  final IconData icon;
  final Tx? transaction;
  final Portfolio? portfolio;
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
      this.lastCreatedMonth,
      this.lastSkippedMonth});
  final String id, description, category, portfolioId;
  final double amount;
  final int dueDay;
  final bool savingsTransfer, recurring;
  final String? destinationPortfolioId, lastCreatedMonth, lastSkippedMonth;
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
        'lastCreatedMonth': lastCreatedMonth,
        'lastSkippedMonth': lastSkippedMonth
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
      lastCreatedMonth: x['lastCreatedMonth'],
      lastSkippedMonth: x['lastSkippedMonth']);
}

enum PortfolioType { bank, creditCard }

const _portfolioIcons = <String, IconData>{
  'bank': Icons.account_balance_outlined,
  'wallet': Icons.account_balance_wallet_outlined,
  'savings': Icons.savings_outlined,
  'card': Icons.credit_card_outlined,
  'investment': Icons.trending_up_outlined,
  'cash': Icons.payments_outlined,
  'home': Icons.home_outlined,
};

IconData _portfolioIcon(Portfolio portfolio) {
  final selected = _portfolioIcons[portfolio.iconKey];
  if (selected != null) return selected;
  if (portfolio.isCreditCard) return Icons.credit_card_outlined;
  if (portfolio.name.toLowerCase().contains('saving'))
    return Icons.savings_outlined;
  return Icons.account_balance_outlined;
}

class Portfolio {
  Portfolio(
      {required this.id,
      required this.name,
      this.opening = 0,
      this.currency = Currency.sar,
      this.type = PortfolioType.bank,
      this.creditLimit = 0,
      this.iconKey,
      List<Tx>? transactions,
      Map<String, double>? categoryCaps})
      : transactions = transactions ?? [],
        categoryCaps = categoryCaps ?? {};
  final String id;
  String name;
  double opening;
  Currency currency;
  PortfolioType type;
  double creditLimit;
  String? iconKey;
  List<Tx> transactions;
  Map<String, double> categoryCaps;
  double get balance =>
      opening +
      transactions.fold(0, (sum, t) => sum + (t.inflow ? t.amount : -t.amount));
  bool get isCreditCard => type == PortfolioType.creditCard;
  double get outstanding =>
      isCreditCard ? (-balance).clamp(0, double.infinity).toDouble() : 0;
  double get availableCredit => isCreditCard
      ? (creditLimit + balance).clamp(0, double.infinity).toDouble()
      : 0;
  double get utilization => creditLimit <= 0 ? 0 : outstanding / creditLimit;
  Map<String, dynamic> json() => {
        'id': id,
        'name': name,
        'opening': opening,
        'currency': currency.name,
        'type': type.name,
        'creditLimit': creditLimit,
        'iconKey': iconKey,
        'transactions': transactions.map((x) => x.json()).toList(),
        'categoryCaps': categoryCaps
      };
  factory Portfolio.fromJson(Map<String, dynamic> x) => Portfolio(
      id: x['id'],
      name: x['name'],
      opening: (x['opening'] as num? ?? x['balance'] as num? ?? 0).toDouble(),
      currency: Currency.values.firstWhere((c) => c.name == x['currency'],
          orElse: () => Currency.sar),
      type: PortfolioType.values.firstWhere((type) => type.name == x['type'],
          orElse: () => PortfolioType.bank),
      creditLimit: (x['creditLimit'] as num? ?? 0).toDouble(),
      iconKey: x['iconKey'],
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
  var globalCategoryCaps = <String, Map<String, double>>{};
  var showGlobalTransactions = false;
  var showGlobalReport = true;
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
  var forceBackup = false;
  var readActivityIds = <String>{};
  Portfolio get current => portfolios.firstWhere((p) => p.id == selected,
      orElse: () => portfolios.first);
  double total(bool inflow) => current.transactions
      .where((t) => t.inflow == inflow && t.transferId == null)
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
    final starterPlans = data.asMap().entries.map((entry) {
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
    final existingIds = monthlyPlans.map((plan) => plan.id).toSet();
    monthlyPlans
        .addAll(starterPlans.where((plan) => !existingIds.contains(plan.id)));
  }

  bool deduplicateMonthlyPlans() {
    final seen = <String>{};
    final unique = <MonthlyPlan>[];
    for (final plan in monthlyPlans) {
      final key =
          '${plan.portfolioId}|${plan.description.trim().toLowerCase()}|'
          '${plan.category}|${plan.amount.toStringAsFixed(2)}|${plan.dueDay}|'
          '${plan.savingsTransfer}|${plan.destinationPortfolioId ?? ''}';
      if (seen.add(key)) unique.add(plan);
    }
    if (unique.length == monthlyPlans.length) return false;
    monthlyPlans = unique;
    return true;
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
          lastCreatedMonth: plan.lastCreatedMonth,
          lastSkippedMonth: plan.lastSkippedMonth);
    }).toList();
  }

  void repairMonthlyPlanReferences() {
    final portfolioIds = portfolios.map((portfolio) => portfolio.id).toSet();
    final fallback =
        portfolioIds.contains(selected) ? selected : portfolios.first.id;
    monthlyPlans = monthlyPlans.map((plan) {
      final source =
          portfolioIds.contains(plan.portfolioId) ? plan.portfolioId : fallback;
      final destination = portfolioIds.contains(plan.destinationPortfolioId)
          ? plan.destinationPortfolioId
          : null;
      if (source == plan.portfolioId &&
          destination == plan.destinationPortfolioId) {
        return plan;
      }
      return MonthlyPlan(
          id: plan.id,
          description: plan.description,
          category: plan.category,
          amount: plan.amount,
          dueDay: plan.dueDay,
          portfolioId: source,
          savingsTransfer: plan.savingsTransfer,
          destinationPortfolioId: destination,
          recurring: plan.recurring,
          lastCreatedMonth: plan.lastCreatedMonth,
          lastSkippedMonth: plan.lastSkippedMonth);
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
    var needsSharedCapsMigration = false;
    var needsPlanDeduplication = false;
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
      readActivityIds = Set<String>.from(d['readActivityIds'] ?? []);
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
      globalCategoryCaps = (d['globalCategoryCaps'] as Map? ?? {}).map(
          (currency, caps) => MapEntry(
              currency.toString(),
              (caps as Map).map((category, amount) =>
                  MapEntry(category.toString(), (amount as num).toDouble()))));
      if (d['capsSharedVersion'] != 2) {
        for (final portfolio in portfolios) {
          final shared = globalCategoryCaps.putIfAbsent(
              portfolio.currency.name, () => <String, double>{});
          for (final entry in portfolio.categoryCaps.entries) {
            if (entry.value > (shared[entry.key] ?? 0)) {
              shared[entry.key] = entry.value;
            }
          }
          portfolio.categoryCaps.clear();
        }
        needsSharedCapsMigration = true;
      }
      monthlyPlans = (d['monthlyPlans'] as List? ?? [])
          .map((x) => MonthlyPlan.fromJson(x))
          .toList();
      // Older snapshots do not have this marker, but may already contain
      // user-managed plans. Seed only an actually empty plan list.
      needsStarterPlans =
          monthlyPlans.isEmpty && d['monthlyPlansSeeded'] != true;
      needsPlanDeduplication = deduplicateMonthlyPlans();
      needsCategoryUpgrade = d['monthlyPlanCategoryVersion'] != 2;
      selected = d['selectedId'] ?? portfolios.first.id;
    }
    if (portfolios.isEmpty) {
      portfolios = [Portfolio(id: 'default', name: 'My portfolio')];
      selected = 'default';
      needsStarterPlans = true;
    }
    if (!portfolios.any((portfolio) => portfolio.id == selected)) {
      selected = portfolios.first.id;
    }
    if (needsStarterPlans) seedMonthlyPlans();
    if (needsCategoryUpgrade) upgradeStarterPlanCategories();
    repairMonthlyPlanReferences();
    if (mounted)
      setState(() {
        loading = false;
        locked = biometricEnabled;
      });
    if (needsStarterPlans ||
        needsCategoryUpgrade ||
        needsSharedCapsMigration ||
        needsPlanDeduplication) {
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
          'biometricEnabled': biometricEnabled,
          'globalCategoryCaps': globalCategoryCaps,
          'capsSharedVersion': 2,
          'readActivityIds': readActivityIds.toList()
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
    await _cloud.from('finance_records').upsert(records);
  }

  Future<void> createScheduledBackup(User user, Map<String, dynamic> state,
      {bool force = false}) async {
    final last = DateTime.tryParse(
        await _secureStorage.read(key: 'my_expensia_last_backup') ?? '');
    if (!force && last != null && DateTime.now().difference(last).inDays < 7)
      return;
    try {
      final records = await _cloud
          .from('finance_records')
          .select('record_type, record_id, payload, updated_at, deleted_at')
          .eq('user_id', user.id);
      await _cloud.from('finance_backups').insert({
        'user_id': user.id,
        'label': 'Automatic mobile backup ${DateTime.now().toIso8601String()}',
        'finance_records': records,
        'flutter_state': state
      });
      await _secureStorage.write(
          key: 'my_expensia_last_backup',
          value: DateTime.now().toIso8601String());
    } catch (_) {
      // Backup availability must not interrupt normal finance syncing.
    }
  }

  Future<void> save() async {
    final data = {
      'name': profileName,
      'email': email,
      'biometricEnabled': biometricEnabled,
      'categories': categories,
      'categoryIcons': categoryIcons,
      'globalCategoryCaps': globalCategoryCaps,
      'capsSharedVersion': 2,
      'categoryVersion': 2,
      'selectedId': selected,
      'portfolios': portfolios.map((p) => p.json()).toList(),
      'monthlyPlans': monthlyPlans.map((p) => p.json()).toList(),
      'readActivityIds': readActivityIds.toList(),
      'monthlyPlansSeeded': true,
      'monthlyPlanCategoryVersion': 2
    };
    await _secureStorage.write(
        key: 'my_expensia_state_v1', value: jsonEncode(data));
    final cloud = Supabase.instance.client;
    final user = cloud.auth.currentUser;
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
        await createScheduledBackup(user, data, force: forceBackup);
        forceBackup = false;
      } catch (_) {}
    }
    await _reminders.schedule(monthlyPlans, portfolios);
  }

  Future<void> createManualBackup() async {
    if (_cloud.auth.currentUser == null) {
      throw Exception('Sign in to create a cloud backup.');
    }
    forceBackup = true;
    await save();
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
    } on AuthRetryableFetchException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Cannot reach cloud sync. Check the tablet internet or DNS settings.')));
      }
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
    final sharedCap = globalCategoryCaps[current.currency.name]?[tx.category];
    final cap = sharedCap ?? current.categoryCaps[tx.category];
    if (cap == null || cap <= 0) return true;
    final now = tx.createdAt;
    final spendingPortfolios = sharedCap == null
        ? [current]
        : portfolios
            .where((portfolio) => portfolio.currency == current.currency);
    final spent = spendingPortfolios
        .expand((portfolio) => portfolio.transactions)
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

  Future<void> transferMoney() async {
    final amount = TextEditingController();
    final description = TextEditingController();
    final destinations = portfolios
        .where((portfolio) =>
            portfolio.id != current.id &&
            portfolio.currency == current.currency)
        .toList();
    if (destinations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Create another portfolio with the same currency first.')));
      return;
    }
    var destination = destinations.first;
    final transfer = await showDialog<
            ({String description, double amount, Portfolio destination})>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialog) => AlertDialog(
                    title: const Text('Transfer money'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(_portfolioIcon(current)),
                          title: Text('From: ${current.name}'),
                          subtitle: Text(current.currency.name.toUpperCase())),
                      DropdownButtonFormField<Portfolio>(
                          value: destination,
                          decoration:
                              const InputDecoration(labelText: 'To portfolio'),
                          items: destinations
                              .map((portfolio) => DropdownMenuItem(
                                  value: portfolio,
                                  child: Row(children: [
                                    Icon(_portfolioIcon(portfolio), size: 18),
                                    const SizedBox(width: 8),
                                    Text(portfolio.name)
                                  ])))
                              .toList(),
                          onChanged: (value) =>
                              setDialog(() => destination = value!)),
                      const SizedBox(height: 10),
                      TextField(
                          controller: amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText: 'Amount',
                              prefixText: '${current.currency.symbol} ')),
                      const SizedBox(height: 10),
                      TextField(
                          controller: description,
                          decoration: const InputDecoration(
                              labelText: 'Description (optional)'))
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, (
                                description: description.text.trim(),
                                amount: double.tryParse(
                                        amount.text.replaceAll(',', '')) ??
                                    0,
                                destination: destination
                              )),
                          child: const Text('Transfer'))
                    ])));
    amount.dispose();
    description.dispose();
    if (transfer == null || transfer.amount <= 0) return;
    final now = DateTime.now();
    final transferId = 'transfer_${now.microsecondsSinceEpoch}';
    final baseDescription = transfer.description.isEmpty
        ? (transfer.destination.isCreditCard
            ? 'Payment to ${transfer.destination.name}'
            : 'Transfer to ${transfer.destination.name}')
        : transfer.description;
    setState(() {
      current.transactions.insert(
          0,
          Tx(
              id: '${now.microsecondsSinceEpoch}_out',
              description: baseDescription,
              category: 'Personal transfer',
              amount: transfer.amount,
              inflow: false,
              createdAt: now,
              transferId: transferId));
      transfer.destination.transactions.insert(
          0,
          Tx(
              id: '${now.microsecondsSinceEpoch}_in',
              description: transfer.description.isEmpty
                  ? 'Transfer from ${current.name}'
                  : transfer.description,
              category: 'Personal transfer',
              amount: transfer.amount,
              inflow: true,
              createdAt: now,
              transferId: transferId));
    });
    await save();
  }

  Future<void> showDetails(Tx tx, [Portfolio? portfolio]) => showDialog<void>(
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
                    Text('Portfolio: ${(portfolio ?? current).name}'),
                    Text('Category: ${tx.category}'),
                    Text(
                        'Amount: ${(portfolio ?? current).currency.symbol} ${tx.amount.toStringAsFixed(2)}'),
                    Text('Date: ${_shortDateTime(tx.createdAt)}'),
                    Text('Day: ${_dayName(tx.createdAt)}')
                  ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'))
              ]));

  List<_ActivityNotice> get activityNotices {
    final now = DateTime.now();
    final notices = <_ActivityNotice>[];
    for (final portfolio in portfolios) {
      for (final tx in portfolio.transactions) {
        notices.add(_ActivityNotice(
            id: 'transaction:${tx.id}',
            title: tx.inflow ? 'Inflow added' : 'Outflow added',
            message:
                '${tx.description} - ${portfolio.currency.symbol} ${tx.amount.toStringAsFixed(2)}',
            createdAt: tx.createdAt,
            icon: tx.inflow
                ? Icons.add_circle_outline
                : Icons.remove_circle_outline,
            transaction: tx,
            portfolio: portfolio));
      }
    }
    for (final entry in globalCategoryCaps.entries) {
      final currency = Currency.values.firstWhere(
          (item) => item.name == entry.key,
          orElse: () => Currency.sar);
      for (final cap in entry.value.entries) {
        if (cap.value <= 0) continue;
        final spent = portfolios
            .where((portfolio) => portfolio.currency == currency)
            .expand((portfolio) => portfolio.transactions)
            .where((tx) =>
                !tx.inflow &&
                tx.transferId == null &&
                tx.category == cap.key &&
                tx.createdAt.year == now.year &&
                tx.createdAt.month == now.month)
            .fold<double>(0, (sum, tx) => sum + tx.amount);
        final ratio = spent / cap.value;
        if (ratio < .9) continue;
        notices.add(_ActivityNotice(
            id: 'cap:${currency.name}:${cap.key}:${now.year}-${now.month}',
            title: ratio >= 1 ? 'Monthly cap exceeded' : 'Monthly cap warning',
            message:
                '${cap.key}: ${(ratio * 100).toStringAsFixed(0)}% of ${currency.symbol} ${cap.value.toStringAsFixed(2)}',
            createdAt: now,
            icon:
                ratio >= 1 ? Icons.warning_amber_rounded : Icons.info_outline));
      }
    }
    notices.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return notices.take(12).toList();
  }

  Future<void> markActivityRead(Iterable<_ActivityNotice> notices) async {
    final ids = notices.map((notice) => notice.id).toSet();
    if (ids.every(readActivityIds.contains)) return;
    setState(() {
      readActivityIds.addAll(ids);
      if (readActivityIds.length > 200) {
        readActivityIds = readActivityIds.toList().sublist(0, 200).toSet();
      }
    });
    await save();
  }

  Widget activityBell(List<_ActivityNotice> notices) {
    final unread =
        notices.where((notice) => !readActivityIds.contains(notice.id)).length;
    return PopupMenuButton<_ActivityNotice>(
        tooltip: unread == 0 ? 'Notifications' : '$unread unread notifications',
        onOpened: () => markActivityRead(notices),
        onSelected: (notice) {
          if (notice.transaction != null) {
            showDetails(notice.transaction!, notice.portfolio);
          }
        },
        itemBuilder: (context) => [
              PopupMenuItem<_ActivityNotice>(
                  enabled: false,
                  child: Row(children: [
                    const Icon(Icons.notifications_outlined),
                    const SizedBox(width: 8),
                    const Text('Notifications',
                        style: TextStyle(fontWeight: FontWeight.bold))
                  ])),
              const PopupMenuDivider(),
              if (notices.isEmpty)
                const PopupMenuItem<_ActivityNotice>(
                    enabled: false, child: Text('No recent activity')),
              ...notices.take(6).map((notice) => PopupMenuItem<_ActivityNotice>(
                  value: notice,
                  child: SizedBox(
                      width: 250,
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(notice.icon,
                                size: 20,
                                color: notice.title.contains('exceeded')
                                    ? Colors.red
                                    : Colors.teal),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(notice.title,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600)),
                                  Text(notice.message,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12))
                                ]))
                          ]))))
            ],
        child: Stack(clipBehavior: Clip.none, children: [
          const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.notifications_outlined)),
          if (unread > 0)
            Positioned(
                right: 2,
                top: 2,
                child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(10)),
                    child: Text(unread > 9 ? '9+' : '$unread',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10))))
        ]));
  }

  Future<void> openDashboard() => Navigator.push<void>(
      context,
      MaterialPageRoute(
          builder: (_) => DashboardPage(
              portfolios: portfolios, globalCaps: globalCategoryCaps)));
  Future<void> openTrends() => Navigator.push<void>(context,
      MaterialPageRoute(builder: (_) => TrendsPage(portfolios: portfolios)));
  Future<void> settings() async {
    Future<void> applySettings(_SettingsData data) async {
      setState(() {
        portfolios = data.portfolios;
        globalCategoryCaps = data.globalCategoryCaps;
        selected = data.selected;
        profileName = data.name;
        email = data.email;
        categories = data.categories;
        categoryIcons = data.categoryIcons;
        monthlyPlans = data.monthlyPlans;
        biometricEnabled = data.biometricEnabled;
      });
      await save();
    }

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
                    globalCategoryCaps: globalCategoryCaps,
                    biometricEnabled: biometricEnabled),
                cloudSignedIn: _cloud.auth.currentUser != null,
                onCloudAccount: connectCloud,
                onBackup: createManualBackup,
                onSave: applySettings)));
    if (r != null) {
      await applySettings(r);
    }
  }

  void createPlanTransaction(MonthlyPlan plan) {
    final source = portfolios.firstWhere((item) => item.id == plan.portfolioId,
        orElse: () => portfolios.firstWhere((item) => item.id == selected,
            orElse: () => portfolios.first));
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
            lastCreatedMonth: month,
            lastSkippedMonth: null);
    });
    save();
  }

  void skipPlanTransaction(MonthlyPlan plan) {
    final now = DateTime.now();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    setState(() {
      final index = monthlyPlans.indexWhere((item) => item.id == plan.id);
      if (index < 0) return;
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
          lastCreatedMonth: null,
          lastSkippedMonth: month);
    });
    save();
  }

  Future<void> openBillCalendar() => Navigator.push<void>(
      context,
      MaterialPageRoute(
          builder: (_) => PlanTransactionsPage(
              plans: monthlyPlans,
              portfolios: portfolios,
              icons: categoryIcons,
              onCreate: createPlanTransaction,
              onSkip: skipPlanTransaction)));
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
    final reportPortfolios = showGlobalReport
        ? portfolios
            .where((portfolio) => portfolio.currency == current.currency)
        : [current];
    final reportPortfolio = showGlobalReport
        ? Portfolio(
            id: 'global-${current.currency.name}',
            name: 'All portfolios',
            currency: current.currency,
            transactions: reportPortfolios
                .expand((portfolio) => portfolio.transactions)
                .toList())
        : current;
    final recentTransactions = (showGlobalTransactions
            ? portfolios.expand((portfolio) => portfolio.transactions.map(
                (transaction) =>
                    (portfolio: portfolio, transaction: transaction)))
            : current.transactions.map((transaction) =>
                (portfolio: current, transaction: transaction)))
        .toList()
      ..sort(
          (a, b) => b.transaction.createdAt.compareTo(a.transaction.createdAt));
    final notices = activityNotices;
    return Scaffold(
        appBar: AppBar(
            title: Text(profileName.isEmpty
                ? 'My Expensia'
                : 'My Expensia - $profileName'),
            actions: [
              IconButton(
                  tooltip: 'Dashboard',
                  onPressed: openDashboard,
                  icon: const Icon(Icons.dashboard_outlined)),
              IconButton(
                  tooltip: 'Spending trends',
                  onPressed: openTrends,
                  icon: const Icon(Icons.insights_outlined)),
              IconButton(
                  tooltip: signedIn ? 'Cloud account connected' : 'Cloud login',
                  onPressed: connectCloud,
                  icon: Icon(signedIn ? Icons.cloud_done : Icons.cloud_outlined,
                      color: signedIn ? Colors.blue.shade700 : null)),
              activityBell(notices),
              IconButton(
                  tooltip: 'Bill calendar',
                  onPressed: openBillCalendar,
                  icon: const Icon(Icons.calendar_month_outlined)),
              IconButton(onPressed: settings, icon: const Icon(Icons.settings))
            ]),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          DropdownButtonFormField<String>(
              initialValue: selected,
              decoration: const InputDecoration(labelText: 'Active portfolio'),
              items: portfolios
                  .map((p) => DropdownMenuItem(
                      value: p.id,
                      child: Row(children: [
                        Icon(_portfolioIcon(p), size: 18),
                        const SizedBox(width: 8),
                        Text(p.name)
                      ])))
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
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(_portfolioIcon(current)),
                      const SizedBox(width: 8),
                      Text(current.name,
                          style: Theme.of(c).textTheme.titleLarge)
                    ]),
                    if (current.isCreditCard)
                      Text(current.balance > 0 ? 'CARD CREDIT' : 'OUTSTANDING',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.blueGrey)),
                    Text(
                        '${current.currency.symbol} ${(current.isCreditCard && current.balance > 0 ? -current.balance : current.isCreditCard ? current.outstanding : current.balance).toStringAsFixed(2)}',
                        style: Theme.of(c).textTheme.displaySmall?.copyWith(
                            color: current.isCreditCard && current.balance > 0
                                ? Colors.teal
                                : null)),
                    if (current.isCreditCard) ...[
                      const SizedBox(height: 8),
                      Text(
                          'Credit limit: ${current.currency.symbol} ${current.creditLimit.toStringAsFixed(2)}'),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                          value: current.utilization.clamp(0, 1).toDouble(),
                          color: current.utilization >= .9
                              ? Colors.red
                              : Colors.blue),
                      const SizedBox(height: 6),
                      Text(
                          'Available credit: ${current.currency.symbol} ${current.availableCredit.toStringAsFixed(2)} (${(current.utilization * 100).toStringAsFixed(1)}% used)')
                    ]
                  ]))),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: Text('Report scope',
                    style: Theme.of(c).textTheme.titleSmall)),
            SegmentedButton<bool>(
                segments: [
                  const ButtonSegment(
                      value: false, label: Text('This portfolio')),
                  ButtonSegment(
                      value: true, label: const Text('All portfolios'))
                ],
                selected: {
                  showGlobalReport
                },
                onSelectionChanged: (value) =>
                    setState(() => showGlobalReport = value.first))
          ]),
          const SizedBox(height: 8),
          _ReportGraph(
              inflow: reportPortfolio.transactions
                  .where((tx) => tx.inflow && tx.transferId == null)
                  .fold(0, (sum, tx) => sum + tx.amount),
              outflow: reportPortfolio.transactions
                  .where((tx) => !tx.inflow && tx.transferId == null)
                  .fold(0, (sum, tx) => sum + tx.amount),
              currency: current.currency,
              onTap: () => Navigator.push(
                  c,
                  MaterialPageRoute(
                      builder: (_) => CategoryReportPage(
                          portfolio: reportPortfolio, icons: categoryIcons)))),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: FilledButton.icon(
                    onPressed: () => addTx(true),
                    icon: const Icon(Icons.add),
                    label: Text(
                        current.isCreditCard ? 'Add payment' : 'Add inflow'))),
            const SizedBox(width: 10),
            Expanded(
                child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.red.shade700),
                    onPressed: () => addTx(false),
                    icon: const Icon(Icons.remove),
                    label: Text(current.isCreditCard
                        ? 'Add card charge'
                        : 'Add outflow')))
          ]),
          const SizedBox(height: 10),
          SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                  onPressed: transferMoney,
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Transfer money'))),
          const SizedBox(height: 24),
          Row(children: [
            Text('Transactions', style: Theme.of(c).textTheme.titleLarge),
            const Spacer(),
            SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('This portfolio')),
                  ButtonSegment(value: true, label: Text('All portfolios'))
                ],
                selected: {
                  showGlobalTransactions
                },
                onSelectionChanged: (value) =>
                    setState(() => showGlobalTransactions = value.first))
          ]),
          const SizedBox(height: 8),
          if (recentTransactions.isEmpty)
            const Padding(
                padding: EdgeInsets.all(20),
                child: const Text('No transactions yet.')),
          ...recentTransactions.take(12).map((entry) {
            final portfolio = entry.portfolio;
            final t = entry.transaction;
            return Card(
                child: ListTile(
                    onTap: () => showDetails(t, portfolio),
                    leading: CircleAvatar(
                        child: Icon(_categoryIcon(t.category, categoryIcons))),
                    title: Text(t.description),
                    subtitle: Text(
                        '${showGlobalTransactions ? '${portfolio.name} - ' : ''}${t.category} - ${_shortDateTime(t.createdAt)}'),
                    trailing: Text(
                        '${t.inflow ? '+' : '-'}${portfolio.currency.symbol} ${t.amount.toStringAsFixed(2)}',
                        style: TextStyle(
                            color: t.inflow ? Colors.teal : Colors.red,
                            fontWeight: FontWeight.bold))));
          })
        ]));
  }
}

class TrendsPage extends StatefulWidget {
  const TrendsPage({super.key, required this.portfolios});
  final List<Portfolio> portfolios;
  @override
  State<TrendsPage> createState() => _TrendsPageState();
}

class _TrendsPageState extends State<TrendsPage> {
  late String selectedMonth;
  List<String> get months => List.generate(6, (index) {
        final date =
            DateTime(DateTime.now().year, DateTime.now().month - 5 + index);
        return '${date.year}-${date.month.toString().padLeft(2, '0')}';
      });
  @override
  void initState() {
    super.initState();
    selectedMonth = months.last;
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.portfolios
        .expand((portfolio) => portfolio.transactions)
        .where((transaction) => transaction.transferId == null)
        .toList();
    final selected = all
        .where((transaction) =>
            '${transaction.createdAt.year}-${transaction.createdAt.month.toString().padLeft(2, '0')}' ==
            selectedMonth)
        .toList();
    final inflow = selected
        .where((transaction) => transaction.inflow)
        .fold(0.0, (sum, transaction) => sum + transaction.amount);
    final outflow = selected
        .where((transaction) => !transaction.inflow)
        .fold(0.0, (sum, transaction) => sum + transaction.amount);
    final total = inflow + outflow == 0 ? 1.0 : inflow + outflow;
    final categories = <String, double>{};
    for (final transaction
        in selected.where((transaction) => !transaction.inflow)) {
      categories[transaction.category] =
          (categories[transaction.category] ?? 0) + transaction.amount;
    }
    final sortedCategories = categories.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Scaffold(
        appBar: AppBar(title: const Text('Spending trends')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          DropdownButtonFormField<String>(
              value: selectedMonth,
              decoration: const InputDecoration(labelText: 'Reporting month'),
              items: months
                  .map((month) =>
                      DropdownMenuItem(value: month, child: Text(month)))
                  .toList(),
              onChanged: (month) => setState(() => selectedMonth = month!)),
          const SizedBox(height: 16),
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(children: [
                    const Text('Inflow vs outflow',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    SizedBox(
                        width: 150,
                        height: 150,
                        child: Stack(alignment: Alignment.center, children: [
                          CircularProgressIndicator(
                              value: inflow / total,
                              strokeWidth: 22,
                              color: Colors.teal,
                              backgroundColor: Colors.amber.shade300),
                          Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(
                                '${(outflow / total * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(
                                    fontSize: 24, fontWeight: FontWeight.bold)),
                            const Text('outflow')
                          ])
                        ])),
                    const SizedBox(height: 10),
                    Text(
                        'Inflow ${inflow.toStringAsFixed(2)}  •  Outflow ${outflow.toStringAsFixed(2)}')
                  ]))),
          const SizedBox(height: 12),
          Row(children: [
            for (final metric in [
              ('INFLOW', inflow, Colors.teal),
              ('OUTFLOW', outflow, Colors.red),
              (
                'NET',
                inflow - outflow,
                inflow >= outflow ? Colors.teal : Colors.red
              )
            ])
              Expanded(
                  child: Card(
                      child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(children: [
                            Text(metric.$1,
                                style: const TextStyle(fontSize: 10)),
                            const SizedBox(height: 6),
                            Text(metric.$2.toStringAsFixed(0),
                                style: TextStyle(
                                    color: metric.$3,
                                    fontWeight: FontWeight.bold))
                          ]))))
          ]),
          const SizedBox(height: 16),
          Text('Category outflow for $selectedMonth',
              style: Theme.of(context).textTheme.titleMedium),
          ...sortedCategories.map((entry) => Card(
              child: ListTile(
                  title: Text(entry.key),
                  trailing: Text(entry.value.toStringAsFixed(2),
                      style: const TextStyle(fontWeight: FontWeight.bold)))))
        ]));
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage(
      {super.key, required this.portfolios, required this.globalCaps});
  final List<Portfolio> portfolios;
  final Map<String, Map<String, double>> globalCaps;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Scaffold(
        appBar: AppBar(title: const Text('Dashboard')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('This month by portfolio.',
              style: TextStyle(color: Colors.blueGrey)),
          const SizedBox(height: 12),
          ...portfolios.map((portfolio) {
            final transactions = portfolio.transactions
                .where((transaction) =>
                    transaction.transferId == null &&
                    transaction.createdAt.year == now.year &&
                    transaction.createdAt.month == now.month)
                .toList();
            final inflow = transactions
                .where((transaction) => transaction.inflow)
                .fold(0.0, (sum, transaction) => sum + transaction.amount);
            final outflow = transactions
                .where((transaction) => !transaction.inflow)
                .fold(0.0, (sum, transaction) => sum + transaction.amount);
            final netWorth = portfolio.balance;
            final caps =
                globalCaps[portfolio.currency.name] ?? portfolio.categoryCaps;
            final alerts = caps.entries
                .map((entry) {
                  final spent = transactions
                      .where((transaction) =>
                          !transaction.inflow &&
                          transaction.category == entry.key)
                      .fold(
                          0.0, (sum, transaction) => sum + transaction.amount);
                  return (category: entry.key, cap: entry.value, spent: spent);
                })
                .where(
                    (alert) => alert.cap > 0 && alert.spent / alert.cap >= .9)
                .toList()
              ..sort((a, b) => (b.spent / b.cap).compareTo(a.spent / a.cap));
            Widget metric(String label, double value, {Color? color}) =>
                Expanded(
                    child: Card(
                        margin: EdgeInsets.zero,
                        color: const Color(0xfff3f7f4),
                        child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(label,
                                      style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 6),
                                  Text(
                                      '${portfolio.currency.symbol} ${value.toStringAsFixed(2)}',
                                      style: TextStyle(
                                          color: color,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold))
                                ]))));
            return Card(
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                                child: Row(children: [
                              Icon(_portfolioIcon(portfolio)),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    Text(portfolio.currency.name.toUpperCase(),
                                        style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.blueGrey)),
                                    Text(portfolio.name.toUpperCase(),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge)
                                  ]))
                            ])),
                            Text(
                                portfolio.isCreditCard
                                    ? 'CREDIT CARD'
                                    : 'BANK / CASH',
                                style: const TextStyle(color: Colors.blueGrey))
                          ]),
                          const SizedBox(height: 12),
                          Row(children: [
                            metric('MONTHLY INFLOW', inflow,
                                color: Colors.teal),
                            const SizedBox(width: 8),
                            metric('MONTHLY OUTFLOW', outflow,
                                color: Colors.red)
                          ]),
                          const SizedBox(height: 8),
                          Row(children: [
                            metric('NET CASHFLOW', inflow - outflow,
                                color: inflow >= outflow
                                    ? Colors.teal
                                    : Colors.red),
                            const SizedBox(width: 8),
                            metric('NET WORTH', netWorth)
                          ]),
                          const SizedBox(height: 16),
                          Text('Budget alerts',
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 6),
                          if (alerts.isEmpty)
                            const Text(
                                'No category is at 90% of its monthly cap.',
                                style: TextStyle(color: Colors.blueGrey)),
                          ...alerts.map((alert) => Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(top: 7),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                  color: const Color(0xfffff4f2),
                                  borderRadius: BorderRadius.circular(8),
                                  border: const Border(
                                      left: BorderSide(
                                          color: Colors.red, width: 3))),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '${alert.category} - ${(alert.spent / alert.cap * 100).toStringAsFixed(0)}% used',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold)),
                                    Text(
                                        '${portfolio.currency.symbol} ${alert.spent.toStringAsFixed(2)} of ${portfolio.currency.symbol} ${alert.cap.toStringAsFixed(2)} monthly cap')
                                  ])))
                        ])));
          })
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
    for (final tx in portfolio.transactions
        .where((tx) => !tx.inflow && tx.transferId == null)) {
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
                          tx.transferId == null &&
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
        .where((tx) =>
            !tx.inflow && tx.transferId == null && tx.category == category)
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
      required this.globalCategoryCaps,
      required this.biometricEnabled});
  final List<Portfolio> portfolios;
  final String selected, name, email;
  final List<String> categories;
  final Map<String, int> categoryIcons;
  final List<MonthlyPlan> monthlyPlans;
  final Map<String, Map<String, double>> globalCategoryCaps;
  final bool biometricEnabled;
}

class Settings extends StatefulWidget {
  const Settings(
      {super.key,
      required this.data,
      required this.cloudSignedIn,
      required this.onCloudAccount,
      required this.onBackup,
      required this.onSave});
  final _SettingsData data;
  final bool cloudSignedIn;
  final Future<void> Function() onCloudAccount;
  final Future<void> Function() onBackup;
  final Future<void> Function(_SettingsData data) onSave;
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
  late Map<String, Map<String, double>> globalCategoryCaps;
  late bool biometricEnabled;
  var backupsOpen = false;
  @override
  void initState() {
    super.initState();
    portfolios = widget.data.portfolios
        .map((p) => Portfolio(
            id: p.id,
            name: p.name,
            opening: p.opening,
            currency: p.currency,
            type: p.type,
            creditLimit: p.creditLimit,
            iconKey: p.iconKey,
            transactions: [...p.transactions],
            categoryCaps: {...p.categoryCaps}))
        .toList();
    selected = widget.data.selected;
    categories = [...widget.data.categories];
    categoryIcons = {...widget.data.categoryIcons};
    monthlyPlans = [...widget.data.monthlyPlans];
    globalCategoryCaps = widget.data.globalCategoryCaps
        .map((currency, caps) => MapEntry(currency, {...caps}));
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
        if ((await auth.getAvailableBiometrics()).isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'Set up a fingerprint or face biometric in device Settings first.')));
          }
          return;
        }
        final confirmed = await auth.authenticate(
            localizedReason: 'Confirm to enable biometric lock',
            biometricOnly: true,
            persistAcrossBackgrounding: true);
        if (!confirmed) return;
      } on LocalAuthException catch (error) {
        final message = switch (error.code) {
          LocalAuthExceptionCode.noCredentialsSet =>
            'Set a secure screen lock and biometric in device Settings first.',
          LocalAuthExceptionCode.noBiometricsEnrolled =>
            'Set up a fingerprint or face biometric in device Settings first.',
          LocalAuthExceptionCode.noBiometricHardware =>
            'This device does not support biometric authentication.',
          LocalAuthExceptionCode.biometricLockout ||
          LocalAuthExceptionCode.temporaryLockout =>
            'Biometrics are temporarily locked. Unlock the device with its PIN, then try again.',
          _ => error.description ?? 'Unable to enable biometric lock.'
        };
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
        }
        return;
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
    final limit = TextEditingController();
    var currency = current.currency;
    var type = PortfolioType.bank;
    var iconKey = 'bank';
    final r = await showDialog<
            ({String name, PortfolioType type, double limit, String iconKey})>(
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
                          onChanged: (v) => setD(() => currency = v!)),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<PortfolioType>(
                          initialValue: type,
                          decoration: const InputDecoration(
                              labelText: 'Portfolio type'),
                          items: const [
                            DropdownMenuItem(
                                value: PortfolioType.bank,
                                child: Text('Bank / cash account')),
                            DropdownMenuItem(
                                value: PortfolioType.creditCard,
                                child: Text('Credit card'))
                          ],
                          onChanged: (v) => setD(() => type = v!)),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                          initialValue: iconKey,
                          decoration: const InputDecoration(
                              labelText: 'Portfolio icon'),
                          items: _portfolioIcons.entries
                              .map((entry) => DropdownMenuItem(
                                  value: entry.key,
                                  child: Row(children: [
                                    Icon(entry.value, size: 18),
                                    const SizedBox(width: 8),
                                    Text(entry.key.toUpperCase())
                                  ])))
                              .toList(),
                          onChanged: (value) => setD(() => iconKey = value!)),
                      if (type == PortfolioType.creditCard) ...[
                        const SizedBox(height: 10),
                        TextField(
                            controller: limit,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: InputDecoration(
                                labelText: 'Credit limit',
                                prefixText: '${currency.symbol} '))
                      ]
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, (
                                name: n.text,
                                type: type,
                                limit: double.tryParse(
                                        limit.text.replaceAll(',', '')) ??
                                    0,
                                iconKey: iconKey
                              )),
                          child: const Text('Add'))
                    ])));
    n.dispose();
    limit.dispose();
    if (r != null &&
        r.name.trim().isNotEmpty &&
        (r.type != PortfolioType.creditCard || r.limit > 0))
      setState(() {
        final p = Portfolio(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: r.name.trim(),
            currency: currency,
            type: r.type,
            creditLimit: r.limit,
            iconKey: r.iconKey);
        portfolios.add(p);
        selected = p.id;
      });
  }

  Future<void> renamePortfolio(Portfolio portfolio) async {
    final name = TextEditingController(text: portfolio.name);
    var iconKey = portfolio.iconKey ??
        (portfolio.isCreditCard
            ? 'card'
            : portfolio.name.toLowerCase().contains('saving')
                ? 'savings'
                : 'bank');
    final updated = await showDialog<({String name, String iconKey})>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialog) => AlertDialog(
                    title: const Text('Rename portfolio'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: name,
                          autofocus: true,
                          decoration: const InputDecoration(
                              labelText: 'Portfolio name')),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                          value: iconKey,
                          decoration: const InputDecoration(
                              labelText: 'Portfolio icon'),
                          items: _portfolioIcons.entries
                              .map((entry) => DropdownMenuItem(
                                  value: entry.key,
                                  child: Row(children: [
                                    Icon(entry.value, size: 18),
                                    const SizedBox(width: 8),
                                    Text(entry.key.toUpperCase())
                                  ])))
                              .toList(),
                          onChanged: (value) =>
                              setDialog(() => iconKey = value!))
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(
                              ctx, (name: name.text, iconKey: iconKey)),
                          child: const Text('Save'))
                    ])));
    if (updated != null && updated.name.trim().isNotEmpty) {
      setState(() {
        portfolio.name = updated.name.trim();
        portfolio.iconKey = updated.iconKey;
      });
    }
  }

  Future<void> setCurrentAmount(Portfolio portfolio) async {
    final value = TextEditingController(
        text: (portfolio.isCreditCard
                ? portfolio.availableCredit
                : portfolio.balance)
            .toStringAsFixed(2));
    final target = await showDialog<double>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(portfolio.isCreditCard
                    ? 'Set available credit'
                    : 'Set current balance'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(portfolio.isCreditCard
                      ? 'Credit limit stays ${portfolio.currency.symbol} ${portfolio.creditLimit.toStringAsFixed(2)}. This adjusts the opening balance while keeping transaction history.'
                      : 'This adjusts the opening balance while keeping transaction history.'),
                  const SizedBox(height: 12),
                  TextField(
                      controller: value,
                      autofocus: true,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText: portfolio.isCreditCard
                              ? 'Available credit'
                              : 'Current balance',
                          prefixText: '${portfolio.currency.symbol} '))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(
                          ctx, double.tryParse(value.text.replaceAll(',', ''))),
                      child: const Text('Save'))
                ]));
    value.dispose();
    if (target == null || target < 0) return;
    final transactionNet = portfolio.transactions.fold<double>(
        0, (sum, tx) => sum + (tx.inflow ? tx.amount : -tx.amount));
    setState(() {
      portfolio.opening = portfolio.isCreditCard
          ? target - portfolio.creditLimit - transactionNet
          : target - transactionNet;
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
    // Also clear a legacy plan marker when its recorded transaction is in this
    // portfolio. This keeps resets correct after portfolios have been renamed.
    final planIdsToReset = monthlyPlans
        .where((plan) =>
            plan.portfolioId == portfolio.id ||
            portfolio.transactions.any((tx) =>
                !tx.inflow &&
                tx.description == plan.description &&
                tx.amount == plan.amount))
        .map((plan) => plan.id)
        .toSet();
    setState(() {
      portfolio.transactions.clear();
      portfolio.opening = 0;
      monthlyPlans = monthlyPlans
          .map((plan) => !planIdsToReset.contains(plan.id)
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
    await widget.onSave(_SettingsData(
        portfolios: portfolios,
        selected: selected,
        name: name.text.trim(),
        email: email.text.trim(),
        categories: categories,
        categoryIcons: categoryIcons,
        monthlyPlans: monthlyPlans,
        globalCategoryCaps: globalCategoryCaps,
        biometricEnabled: biometricEnabled));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${portfolio.name} has been reset and synced.')));
    }
  }

  Future<void> deletePortfolio(Portfolio portfolio) async {
    if (portfolios.length == 1) return;
    final replacement = portfolios.firstWhere(
        (item) => item.id != portfolio.id && item.name == 'My portfolio SNB',
        orElse: () => portfolios.firstWhere((item) => item.id != portfolio.id));
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text('Delete ${portfolio.name}?'),
                content: Text(
                    'Its transactions and related monthly plans will be removed. ${replacement.name} will become active.'),
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
    final transactionIds = portfolio.transactions.map((tx) => tx.id).toList();
    final planIds = monthlyPlans
        .where((plan) =>
            plan.portfolioId == portfolio.id ||
            plan.destinationPortfolioId == portfolio.id)
        .map((plan) => plan.id)
        .toList();
    setState(() {
      portfolios.removeWhere((item) => item.id == portfolio.id);
      monthlyPlans = monthlyPlans
          .where((plan) =>
              plan.portfolioId != portfolio.id &&
              plan.destinationPortfolioId != portfolio.id)
          .toList();
      selected = replacement.id;
    });
    await widget.onSave(_SettingsData(
        portfolios: portfolios,
        selected: selected,
        name: name.text.trim(),
        email: email.text.trim(),
        categories: categories,
        categoryIcons: categoryIcons,
        monthlyPlans: monthlyPlans,
        globalCategoryCaps: globalCategoryCaps,
        biometricEnabled: biometricEnabled));
    await archiveSharedRecords('portfolio', [portfolio.id]);
    await archiveSharedRecords('transaction', transactionIds);
    await archiveSharedRecords('plan', planIds);
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
                selectedPortfolioId: selected,
                icons: categoryIcons,
                plans: monthlyPlans,
                categories: categories,
                onDeleted: archiveTransactions)));
    setState(() {});
  }

  Future<void> archiveTransactions(List<String> transactionIds) async {
    await archiveSharedRecords('transaction', transactionIds);
  }

  Future<void> archiveSharedRecords(
      String recordType, List<String> recordIds) async {
    final cloud = Supabase.instance.client;
    final user = cloud.auth.currentUser;
    if (user == null || recordIds.isEmpty) return;
    await cloud
        .from('finance_records')
        .update({'deleted_at': DateTime.now().toIso8601String()})
        .eq('user_id', user.id)
        .eq('record_type', recordType)
        .inFilter('record_id', recordIds);
  }

  Future<void> openPlans() async {
    final initialPlanIds = monthlyPlans.map((plan) => plan.id).toSet();
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => MonthlyPlansPage(
                plans: monthlyPlans,
                portfolios: portfolios,
                categories: categories,
                icons: categoryIcons)));
    setState(() {});
    final remainingPlanIds = monthlyPlans.map((plan) => plan.id).toSet();
    await archiveSharedRecords(
        'plan', initialPlanIds.difference(remainingPlanIds).toList());
  }

  Future<void> openCaps() async {
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => MonthlyCapsPage(
                portfolios: portfolios,
                initialSelected: selected,
                categories: categories,
                icons: categoryIcons,
                globalCaps: globalCategoryCaps)));
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
          globalCategoryCaps: globalCategoryCaps,
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
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.backup_outlined),
                title: const Text('Import, export, and backups'),
                trailing:
                    Icon(backupsOpen ? Icons.expand_less : Icons.expand_more),
                onTap: () => setState(() => backupsOpen = !backupsOpen)),
            if (backupsOpen)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                                'Automatic cloud backups run weekly while you use the app.'),
                            const SizedBox(height: 10),
                            FilledButton.icon(
                                onPressed: widget.cloudSignedIn
                                    ? () async {
                                        try {
                                          await widget.onBackup();
                                          if (mounted)
                                            ScaffoldMessenger.of(c)
                                                .showSnackBar(const SnackBar(
                                                    content: Text(
                                                        'Cloud backup created.')));
                                        } catch (error) {
                                          if (mounted)
                                            ScaffoldMessenger.of(c)
                                                .showSnackBar(SnackBar(
                                                    content: Text(
                                                        error.toString())));
                                        }
                                      }
                                    : null,
                                icon: const Icon(Icons.cloud_upload_outlined),
                                label: const Text('Create cloud backup'))
                          ]))),
            const SizedBox(height: 20),
            const Text('Portfolios',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ...portfolios.map((p) => ListTile(
                onTap: () => setState(() => selected = p.id),
                leading: CircleAvatar(
                    child: Icon(p.id == selected
                        ? Icons.check_circle
                        : _portfolioIcon(p))),
                title: Text(p.name),
                subtitle: Text(p.isCreditCard
                    ? '${p.currency.nameLabel} - limit ${p.currency.symbol} ${p.creditLimit.toStringAsFixed(2)}'
                    : p.currency.nameLabel),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'Rename portfolio',
                      onPressed: () => renamePortfolio(p),
                      icon: const Icon(Icons.edit_outlined)),
                  IconButton(
                      tooltip: p.isCreditCard
                          ? 'Set available credit'
                          : 'Set current balance',
                      onPressed: () => setCurrentAmount(p),
                      icon: const Icon(Icons.tune_outlined)),
                  IconButton(
                      tooltip: 'Reset portfolio data',
                      onPressed: () => resetPortfolio(p),
                      icon: const Icon(Icons.restart_alt_outlined)),
                  if (portfolios.length > 1)
                    IconButton(
                        tooltip: 'Delete portfolio',
                        onPressed: () => deletePortfolio(p),
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
      required this.selectedPortfolioId,
      required this.icons,
      required this.plans,
      required this.categories,
      required this.onDeleted});
  final List<Portfolio> portfolios;
  final String selectedPortfolioId;
  final Map<String, int> icons;
  final List<MonthlyPlan> plans;
  final List<String> categories;
  final Future<void> Function(List<String>) onDeleted;
  @override
  State<AllTransactionsPage> createState() => _AllTransactionsPageState();
}

class _AllTransactionsPageState extends State<AllTransactionsPage> {
  var showAllPortfolios = true;

  List<(Portfolio, Tx)> get entries {
    final result = <(Portfolio, Tx)>[];
    for (final portfolio in widget.portfolios) {
      if (!showAllPortfolios && portfolio.id != widget.selectedPortfolioId) {
        continue;
      }
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
    final removedIds = <String>{};
    if (tx.transferId != null) {
      for (final item in widget.portfolios) {
        removedIds.addAll(item.transactions
            .where((entry) => entry.transferId == tx.transferId)
            .map((entry) => entry.id));
      }
    } else {
      removedIds.add(tx.id);
      final pairedId = tx.id.endsWith('_out')
          ? '${tx.id.substring(0, tx.id.length - 4)}_in'
          : tx.id.endsWith('_in')
              ? '${tx.id.substring(0, tx.id.length - 3)}_out'
              : null;
      if (pairedId != null) removedIds.add(pairedId);
    }
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
    await widget.onDeleted(removedIds.toList());
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Transaction deleted and balance reversed.')));
  }

  @override
  Widget build(BuildContext context) {
    final data = entries;
    return Scaffold(
        appBar: AppBar(title: const Text('Transaction history')),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(children: [
                const Expanded(child: Text('History scope')),
                SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                          value: false, label: Text('This portfolio')),
                      ButtonSegment(value: true, label: Text('All portfolios'))
                    ],
                    selected: {
                      showAllPortfolios
                    },
                    onSelectionChanged: (value) =>
                        setState(() => showAllPortfolios = value.first))
              ])),
          Expanded(
              child: data.isEmpty
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
                                    child: Icon(_categoryIcon(
                                        tx.category, widget.icons))),
                                title: Text(tx.description),
                                subtitle: Text(
                                    '${portfolio.name} - ${tx.category}\n${_shortDateTime(tx.createdAt)}'),
                                isThreeLine: true,
                                trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                          '${tx.inflow ? '+' : '-'}${portfolio.currency.symbol} ${tx.amount.toStringAsFixed(2)}',
                                          style: TextStyle(
                                              color: tx.inflow
                                                  ? Colors.teal
                                                  : Colors.red,
                                              fontWeight: FontWeight.bold)),
                                      IconButton(
                                          tooltip: 'Edit transaction',
                                          onPressed: () => edit(portfolio, tx),
                                          icon:
                                              const Icon(Icons.edit_outlined)),
                                      IconButton(
                                          tooltip: 'Delete and reverse',
                                          onPressed: () =>
                                              remove(portfolio, tx),
                                          icon:
                                              const Icon(Icons.delete_outline))
                                    ])));
                      }).toList()))
        ]));
  }
}

class PlanTransactionsPage extends StatefulWidget {
  const PlanTransactionsPage(
      {super.key,
      required this.plans,
      required this.portfolios,
      required this.icons,
      required this.onCreate,
      required this.onSkip});
  final List<MonthlyPlan> plans;
  final List<Portfolio> portfolios;
  final Map<String, int> icons;
  final void Function(MonthlyPlan) onCreate;
  final void Function(MonthlyPlan) onSkip;
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
        plan.lastSkippedMonth == month ||
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

  Future<void> skip(MonthlyPlan plan) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text('Skip ${plan.description}?'),
                content: const Text(
                    'No transaction will be created. The plan will be available again next month.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Skip this month'))
                ]));
    if (confirmed != true) return;
    widget.onSkip(plan);
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${plan.description} skipped this month.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ordered = [...widget.plans]
      ..sort((a, b) => a.dueDay.compareTo(b.dueDay));
    final now = DateTime.now();
    final firstDay = DateTime(now.year, now.month, 1);
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final calendarCells = firstDay.weekday % 7 + daysInMonth;
    return Scaffold(
      appBar: AppBar(title: const Text('Bill calendar')),
      body: ordered.isEmpty
          ? const Center(child: Text('No monthly plans yet.'))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text('Bill calendar',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                const Text(
                    'Use Create now when you want to record a planned expense or savings transfer.'),
                const SizedBox(height: 14),
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${_monthName(now.month)} ${now.year} calendar',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 10),
                              const Row(children: [
                                Expanded(child: Center(child: Text('Sun'))),
                                Expanded(child: Center(child: Text('Mon'))),
                                Expanded(child: Center(child: Text('Tue'))),
                                Expanded(child: Center(child: Text('Wed'))),
                                Expanded(child: Center(child: Text('Thu'))),
                                Expanded(child: Center(child: Text('Fri'))),
                                Expanded(child: Center(child: Text('Sat')))
                              ]),
                              const SizedBox(height: 4),
                              GridView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: calendarCells,
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: 7,
                                          childAspectRatio: .82),
                                  itemBuilder: (context, index) {
                                    final day =
                                        index - firstDay.weekday % 7 + 1;
                                    if (day < 1 || day > daysInMonth) {
                                      return const SizedBox.shrink();
                                    }
                                    final plans = ordered
                                        .where((plan) => plan.dueDay == day)
                                        .toList();
                                    final pending = plans
                                        .where((plan) =>
                                            !createdThisMonth(plan, now))
                                        .toList();
                                    return InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: pending.length == 1
                                            ? () => create(pending.first)
                                            : null,
                                        child: Container(
                                            margin: const EdgeInsets.all(2),
                                            padding: const EdgeInsets.all(4),
                                            decoration: BoxDecoration(
                                                color: day == now.day
                                                    ? Colors.teal.shade50
                                                    : plans.isEmpty
                                                        ? null
                                                        : Colors
                                                            .blueGrey.shade50,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                    color: day == now.day
                                                        ? Colors.teal
                                                        : Colors.transparent)),
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text('$day',
                                                      style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold)),
                                                  ...plans.take(2).map((plan) => Text(
                                                      plan.description,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                          fontSize: 8,
                                                          color: createdThisMonth(
                                                                  plan, now)
                                                              ? Colors.blueGrey
                                                              : Colors.teal
                                                                  .shade800)))
                                                ])));
                                  }),
                              const SizedBox(height: 8),
                              const Text(
                                  'Tap a date with one pending plan to create it. Use the list below for more options.',
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.blueGrey))
                            ]))),
                const SizedBox(height: 8),
                ...ordered.map((plan) {
                  final source = portfolio(plan.portfolioId);
                  final destination = plan.destinationPortfolioId == null
                      ? null
                      : portfolio(plan.destinationPortfolioId!);
                  final isCreated = createdThisMonth(plan, now);
                  final isSkipped = plan.lastSkippedMonth ==
                      '${now.year}-${now.month.toString().padLeft(2, '0')}';
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
                              child: isCreated
                                  ? FilledButton.icon(
                                      onPressed: null,
                                      icon: Icon(isSkipped
                                          ? Icons.skip_next_outlined
                                          : Icons.check),
                                      label: Text(isSkipped
                                          ? 'Skipped this month'
                                          : 'Created this month'))
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        OutlinedButton(
                                            onPressed: () => skip(plan),
                                            child:
                                                const Text('Skip this month')),
                                        const SizedBox(width: 8),
                                        FilledButton.icon(
                                            onPressed: () => create(plan),
                                            icon: const Icon(Icons.play_arrow),
                                            label: const Text('Create now'))
                                      ],
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
  void removeDuplicates() {
    final seen = <String>{};
    final duplicateIds = <String>{};
    for (final plan in widget.plans) {
      final key =
          '${plan.portfolioId}|${plan.description.trim().toLowerCase()}|'
          '${plan.category}|${plan.amount.toStringAsFixed(2)}|${plan.dueDay}|'
          '${plan.savingsTransfer}|${plan.destinationPortfolioId ?? ''}';
      if (!seen.add(key)) duplicateIds.add(plan.id);
    }
    if (duplicateIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No duplicate monthly plans found.')));
      return;
    }
    setState(() {
      widget.plans.removeWhere((plan) => duplicateIds.contains(plan.id));
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${duplicateIds.length} duplicate plan(s) removed.')));
  }

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
                                          existing?.lastCreatedMonth,
                                      lastSkippedMonth:
                                          existing?.lastSkippedMonth));
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
        appBar: AppBar(title: const Text('Monthly plans'), actions: [
          IconButton(
              tooltip: 'Remove duplicate plans',
              onPressed: removeDuplicates,
              icon: const Icon(Icons.content_copy_outlined))
        ]),
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
      required this.icons,
      required this.globalCaps});
  final List<Portfolio> portfolios;
  final String initialSelected;
  final List<String> categories;
  final Map<String, int> icons;
  final Map<String, Map<String, double>> globalCaps;
  @override
  State<MonthlyCapsPage> createState() => _MonthlyCapsPageState();
}

class _MonthlyCapsPageState extends State<MonthlyCapsPage> {
  late String selected;
  var shared = false;
  @override
  void initState() {
    super.initState();
    selected = widget.initialSelected;
  }

  Portfolio get portfolio =>
      widget.portfolios.firstWhere((item) => item.id == selected);
  Map<String, double> get caps => shared
      ? widget.globalCaps.putIfAbsent(portfolio.currency.name, () => {})
      : portfolio.categoryCaps;
  Future<void> editCap(String category) async {
    final amount =
        TextEditingController(text: caps[category]?.toStringAsFixed(2) ?? '');
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
          caps.remove(category);
        } else {
          caps[category] = value;
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
        const SizedBox(height: 10),
        DropdownButtonFormField<bool>(
            initialValue: shared,
            decoration: const InputDecoration(labelText: 'Cap mode'),
            items: [
              const DropdownMenuItem(
                  value: false, child: Text('Per portfolio')),
              DropdownMenuItem(
                  value: true,
                  child: Text(
                      'Shared across ${portfolio.currency.nameLabel} portfolios'))
            ],
            onChanged: (value) => setState(() => shared = value!)),
        const SizedBox(height: 20),
        Text('Monthly category caps',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(shared
            ? 'Caps are shared by all ${portfolio.currency.nameLabel} portfolios and reset on the 1st of every month.'
            : 'Caps apply only to ${portfolio.name} and reset on the 1st of every month.'),
        const SizedBox(height: 16),
        ...widget.categories.map((category) {
          final cap = caps[category];
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
