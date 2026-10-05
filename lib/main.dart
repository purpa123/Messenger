import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = 'https://vepgxpgasbkrloaaxgvh.supabase.co';
const supabasePublishableKey = 'sb_publishable_dIP2ZG4M85bRh771f4mh9A_DuSyGub4';
const devBuild = bool.fromEnvironment('DEV_BUILD', defaultValue: false);

SupabaseClient get sb => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabasePublishableKey,
  );
  runApp(const MessengerApp());
}

class MessengerApp extends StatelessWidget {
  const MessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: devBuild,
      title: devBuild ? 'Messenger DEV' : 'Messenger',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = sb.auth.onAuthStateChange.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return sb.auth.currentSession == null
        ? const AuthPage()
        : const ProfileGate();
  }
}

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _login = true;
  bool _busy = false;
  bool _accepted = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _submit() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      _message('Enter your email and password.');
      return;
    }
    if (!_login && !_accepted) {
      _message('Please accept the Terms, Privacy Policy, Terms of Use, and Rules.');
      return;
    }

    setState(() => _busy = true);
    try {
      if (_login) {
        await sb.auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      } else {
        final response = await sb.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
        );
        if (response.session == null && mounted) {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => CheckEmailPage(email: _email.text.trim())));
        }
      }
    } on AuthException catch (e) {
      if (mounted) _message(e.message);
    } catch (e) {
      if (mounted) _message('Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.forum_rounded, size: 72),
                  const SizedBox(height: 16),
                  Text(
                    _login ? 'Welcome back' : 'Create account',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!_login)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _accepted,
                      onChanged: _busy ? null : (value) => setState(() => _accepted = value ?? false),
                      title: const Text('I agree to the ToS, Privacy Policy, ToU, and Rules', style: TextStyle(fontSize: 13)),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: Text(
                        _busy
                            ? 'Please wait...'
                            : (_login ? 'Sign in' : 'Sign up'),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _login = !_login),
                    child: Text(
                      _login
                          ? 'Create an account'
                          : 'I already have an account',
                    ),
                  ),
                  Wrap(alignment: WrapAlignment.center, children: [
                    for (final item in const [('ToS', tosText), ('Privacy', privacyText), ('ToU', touText), ('Rules', rulesText)])
                      TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => LegalPage(title: item.$1, body: item.$2))), child: Text(item.$1)),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CheckEmailPage extends StatelessWidget {
  final String email;
  const CheckEmailPage({super.key, required this.email});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: Center(child: Padding(padding: const EdgeInsets.all(28), child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.mark_email_unread_outlined, size: 76),
        const SizedBox(height: 18),
        Text('Check your email', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 12),
        Text('We sent a confirmation link to $email. Open it to confirm your account, then return here and sign in.', textAlign: TextAlign.center),
        const SizedBox(height: 22),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Back to sign in')),
      ]),
    ))),
  );
}

class LegalPage extends StatelessWidget {
  final String title;
  final String body;
  const LegalPage({super.key, required this.title, required this.body});
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(title)), body: ListView(padding: const EdgeInsets.all(20), children: [Text(body)]));
}

const tosText = 'Messenger Terms of Service (v0.2.0)\n\nUse the service lawfully and respectfully. Do not abuse, harass, threaten, spam, impersonate others, distribute malware, or attempt unauthorized access. Accounts may be restricted for serious or repeated violations. The service is provided as an early test version and features may change.';
const privacyText = 'Privacy Policy (v0.2.0)\n\nMessenger stores account information, profile information, conversations, messages, and timestamps needed to operate the service. Authentication and database services are provided through Supabase. Do not put sensitive information in your profile. This test version does not yet claim end-to-end encryption.';
const touText = 'Terms of Use (v0.2.0)\n\nKeep your account credentials private. Do not interfere with the service, evade moderation, automate spam, or misuse other users information. Features marked as experimental may change or be unavailable.';
const rulesText = 'Messenger Rules\n\n1. Respect other users.\n2. No harassment, threats, hate speech, or bullying.\n3. No spam, scams, impersonation, or malicious links.\n4. Do not share another persons private information without permission.\n5. Follow applicable laws and platform rules.';

class ProfileGate extends StatefulWidget {
  const ProfileGate({super.key});

  @override
  State<ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends State<ProfileGate> {
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  bool _loading = true;
  bool _exists = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _checkProfile();
  }

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _checkProfile() async {
    final user = sb.auth.currentUser;
    if (user == null) return;

    try {
      final profile = await sb
          .from('profiles')
          .select('id')
          .eq('id', user.id)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _exists = profile != null;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load profile: $e')),
        );
      }
    }
  }

  Future<void> _saveProfile() async {
    final username = _username.text.trim();
    final displayName = _displayName.text.trim();
    final user = sb.auth.currentUser;
    if (user == null) return;

    if (!RegExp(r'^[A-Za-z0-9_]{3,24}$').hasMatch(username)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Username must be 3-24 letters, numbers, or underscores.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await sb.from('profiles').insert({
        'id': user.id,
        'username': username,
        'display_name': displayName,
      });
      await _checkProfile();
    } on PostgrestException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_exists) return const HomePage();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up profile'),
        actions: [
          IconButton(
            onPressed: () => sb.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: 'Username (3-24)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _displayName,
            decoration: const InputDecoration(
              labelText: 'Display name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _saveProfile,
            child: Text(_saving ? 'Saving...' : 'Continue'),
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, dynamic>> _chats = [];
  bool _loading = true;
  Timer? _heartbeat;

  @override
  void initState() {
    super.initState();
    _touchPresence();
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) => _touchPresence());
    _loadChats();
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    super.dispose();
  }

  Future<void> _touchPresence() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    try {
      await sb.from('profiles').update({
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', me);
    } catch (_) {}
  }

  Future<void> _loadChats() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;

    try {
      final rows = await sb.rpc('get_my_dm_inbox');
      final output = <Map<String, dynamic>>[];
      for (final raw in rows) {
        final conversation = Map<String, dynamic>.from(raw);
        final otherId = conversation['other_user_id'] as String?;
        if (otherId == null) continue;
        conversation['id'] = conversation['conversation_id'];

        final profile = await sb
            .from('profiles')
            .select('username,display_name,avatar_url,role,verified,last_seen_at')
            .eq('id', otherId)
            .maybeSingle();

        final membership = await sb
            .from('conversation_members')
            .select('muted')
            .eq('conversation_id', conversation['id'])
            .eq('user_id', me)
            .maybeSingle();

        conversation['other_id'] = otherId;
        conversation['profile'] = profile;
        conversation['muted'] = membership?['muted'] == true;
        output.add(conversation);

        await sb.from('conversation_members').update({
          'delivered_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('conversation_id', conversation['id']).eq('user_id', me);
      }
      output.sort((a, b) => (b['last_message_at'] ?? '')
          .toString()
          .compareTo((a['last_message_at'] ?? '').toString()));

      if (mounted) {
        setState(() {
          _chats = output;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load chats: $e')),
        );
      }
    }
  }

  bool _isOnline(String? raw) {
    final dt = raw == null ? null : DateTime.tryParse(raw);
    return dt != null && DateTime.now().toUtc().difference(dt.toUtc()).inSeconds < 100;
  }

  ImageProvider? _avatar(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    final uri = Uri.tryParse(url.trim());
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
        ? NetworkImage(url.trim())
        : null;
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_chats.isEmpty) {
      body = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 180),
          Center(child: Text('No chats yet. Tap + to find someone.')),
        ],
      );
    } else {
      body = ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _chats.length,
        itemBuilder: (context, index) {
          final chat = _chats[index];
          final profile = chat['profile'] as Map<String, dynamic>?;
          final username = (profile?['username'] ?? 'Unknown').toString();
          final displayName = (profile?['display_name'] ?? '').toString().trim();
          final title = displayName.isEmpty ? '@$username' : displayName;
          final initial = username.isEmpty ? '?' : username[0].toUpperCase();
          final avatar = _avatar(profile?['avatar_url']?.toString());

          return ListTile(
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(backgroundImage: avatar, child: avatar == null ? Text(initial) : null),
                if (_isOnline(profile?['last_seen_at']?.toString()))
                  const Positioned(
                    right: -1,
                    bottom: -1,
                    child: CircleAvatar(radius: 6, backgroundColor: Colors.greenAccent),
                  ),
              ],
            ),
            title: Row(children: [
              Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
              if (profile?['verified'] == true) ...[
                const SizedBox(width: 5),
                const Icon(Icons.verified, size: 18, color: Colors.lightBlueAccent),
              ],
              if (profile?['role'] == 'owner') ...[
                const SizedBox(width: 5),
                const Text('OWNER', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
              ],
              if (chat['muted'] == true) ...[
                const SizedBox(width: 5),
                const Icon(Icons.notifications_off_outlined, size: 16),
              ],
            ]),
            subtitle: Text('@$username'),
            trailing: (chat['unread_count'] as num? ?? 0) > 0
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(20)),
                    child: Text('${chat['unread_count']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  )
                : null,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatPage(
                    conversationId: chat['id'] as String,
                    otherUserId: chat['other_id'] as String,
                    title: title,
                  ),
                ),
              );
              await _loadChats();
            },
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          const Text('Messenger'),
          if (devBuild) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.orangeAccent),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('DEV', style: TextStyle(fontSize: 11, color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
            ),
          ],
        ]),
        actions: [
          IconButton(
            tooltip: 'Profile',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfilePage())),
            icon: const Icon(Icons.person_outline),
          ),
          FutureBuilder<Map<String, dynamic>?>(
            future: sb.from('profiles').select('role').eq('id', sb.auth.currentUser!.id).maybeSingle(),
            builder: (context, snap) => snap.data?['role'] == 'owner'
                ? IconButton(
                    tooltip: 'Admin panel',
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPage())),
                    icon: const Icon(Icons.admin_panel_settings_outlined),
                  )
                : const SizedBox.shrink(),
          ),
          IconButton(onPressed: () => sb.auth.signOut(), icon: const Icon(Icons.logout)),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchPage()));
          await _loadChats();
        },
        child: const Icon(Icons.add_comment_outlined),
      ),
      body: RefreshIndicator(onRefresh: _loadChats, child: body),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _query = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _busy = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(String value) async {
    final query = value.trim();
    if (query.isEmpty) {
      if (mounted) setState(() => _results = []);
      return;
    }
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    try {
      final rows = await sb
          .from('profiles')
          .select('id,username,display_name,avatar_url,bio,role,verified,last_seen_at')
          .ilike('username', '%$query%')
          .neq('id', me)
          .limit(30);
      if (mounted) setState(() => _results = List<Map<String, dynamic>>.from(rows));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Search failed: $e')));
    }
  }

  Future<bool> _blockedBetween(String me, String other) async {
    final a = await sb.from('user_blocks').select('blocker_id').eq('blocker_id', me).eq('blocked_id', other).maybeSingle();
    if (a != null) return true;
    final b = await sb.from('user_blocks').select('blocker_id').eq('blocker_id', other).eq('blocked_id', me).maybeSingle();
    return b != null;
  }

  Future<void> _openChat(Map<String, dynamic> profile) async {
    if (_busy) return;
    final me = sb.auth.currentUser?.id;
    final other = profile['id'] as String?;
    if (me == null || other == null) return;

    setState(() => _busy = true);
    try {
      if (await _blockedBetween(me, other)) {
        throw const FormatException('This conversation is blocked.');
      }

      final low = me.compareTo(other) < 0 ? me : other;
      final high = me.compareTo(other) < 0 ? other : me;
      var conversation = await sb
          .from('conversations')
          .select('id')
          .eq('dm_user_low', low)
          .eq('dm_user_high', high)
          .maybeSingle();

      String conversationId;
      if (conversation != null) {
        conversationId = conversation['id'] as String;
      } else {
        try {
          final created = await sb
              .from('conversations')
              .insert({'created_by': me, 'kind': 'dm', 'dm_user_low': low, 'dm_user_high': high})
              .select('id')
              .single();
          conversationId = created['id'] as String;
        } on PostgrestException catch (e) {
          if (e.code != '23505') rethrow;
          final existing = await sb
              .from('conversations')
              .select('id')
              .eq('dm_user_low', low)
              .eq('dm_user_high', high)
              .single();
          conversationId = existing['id'] as String;
        }

        final existingMembership = await sb
            .from('conversation_members')
            .select('user_id')
            .eq('conversation_id', conversationId);
        final memberIds = existingMembership.map((row) => row['user_id'] as String).toSet();
        final missing = <Map<String, dynamic>>[];
        if (!memberIds.contains(me)) missing.add({'conversation_id': conversationId, 'user_id': me});
        if (!memberIds.contains(other)) missing.add({'conversation_id': conversationId, 'user_id': other});
        if (missing.isNotEmpty) await sb.from('conversation_members').insert(missing);
      }

      if (!mounted) return;
      final displayName = (profile['display_name'] ?? '').toString().trim();
      final username = (profile['username'] ?? 'Unknown').toString();
      final title = displayName.isEmpty ? '@$username' : displayName;
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ChatPage(conversationId: conversationId, otherUserId: other, title: title),
        ),
      );
    } on FormatException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open chat: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _query,
          autofocus: true,
          onChanged: _search,
          decoration: const InputDecoration(hintText: 'Search username...', border: InputBorder.none),
        ),
      ),
      body: Stack(
        children: [
          ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, index) {
              final profile = _results[index];
              final username = (profile['username'] ?? 'Unknown').toString();
              final displayName = (profile['display_name'] ?? '').toString().trim();
              return ListTile(
                leading: CircleAvatar(child: Text(username.isEmpty ? '?' : username[0].toUpperCase())),
                title: Row(children: [
                  Flexible(child: Text(displayName.isEmpty ? '@$username' : displayName)),
                  if (profile['verified'] == true) ...[
                    const SizedBox(width: 5),
                    const Icon(Icons.verified, size: 18, color: Colors.lightBlueAccent),
                  ],
                  if (profile['role'] == 'owner') ...[
                    const SizedBox(width: 5),
                    const Text('OWNER', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                ]),
                subtitle: Text('@$username'),
                onTap: _busy ? null : () => _openChat(profile),
                onLongPress: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => UserProfilePage(userId: profile['id'] as String)),
                ),
              );
            },
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(color: Color(0x55000000), child: Center(child: CircularProgressIndicator())),
            ),
        ],
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  final String conversationId;
  final String otherUserId;
  final String title;
  const ChatPage({super.key, required this.conversationId, required this.otherUserId, required this.title});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final Stream<List<Map<String, dynamic>>> _messages;
  late final Stream<List<Map<String, dynamic>>> _typing;
  late final Stream<List<Map<String, dynamic>>> _reactions;
  late final Stream<List<Map<String, dynamic>>> _pins;
  bool _sending = false;
  bool _muted = false;
  bool _otherOnline = false;
  String _otherStatus = '';
  DateTime? _otherDelivered;
  DateTime? _otherLastRead;
  int _lastMessageCount = -1;
  Map<String, dynamic>? _replyingTo;
  Map<String, dynamic>? _editing;
  List<Map<String, dynamic>> _latestMessages = [];
  Timer? _typingStop;
  Timer? _receiptRefresh;
  bool _typingSent = false;

  @override
  void initState() {
    super.initState();
    _messages = sb.from('messages').stream(primaryKey: ['id']).eq('conversation_id', widget.conversationId).order('created_at', ascending: true);
    _typing = sb.from('typing_states').stream(primaryKey: ['conversation_id', 'user_id']).eq('conversation_id', widget.conversationId);
    _reactions = sb.from('message_reactions').stream(primaryKey: ['message_id', 'user_id', 'emoji']).eq('conversation_id', widget.conversationId);
    _pins = sb.from('conversation_pins').stream(primaryKey: ['conversation_id']).eq('conversation_id', widget.conversationId);
    _markRead();
    _loadReceipt();
    _loadOtherPresence();
    _loadMuted();
    _receiptRefresh = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadReceipt();
      _loadOtherPresence();
    });
  }

  @override
  void dispose() {
    _typingStop?.cancel();
    _receiptRefresh?.cancel();
    _setTyping(false);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _markRead() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await sb.from('conversation_members').update({'last_read_at': now, 'delivered_at': now})
          .eq('conversation_id', widget.conversationId)
          .eq('user_id', me);
    } catch (_) {}
  }

  Future<void> _loadReceipt() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    try {
      final rows = await sb.from('conversation_members')
          .select('user_id,delivered_at,last_read_at')
          .eq('conversation_id', widget.conversationId)
          .neq('user_id', me);
      if (rows.isNotEmpty && mounted) {
        final d = rows.first['delivered_at'] as String?;
        final r = rows.first['last_read_at'] as String?;
        setState(() {
          _otherDelivered = d == null ? null : DateTime.tryParse(d);
          _otherLastRead = r == null ? null : DateTime.tryParse(r);
        });
      }
    } catch (_) {}
  }

  Future<void> _loadOtherPresence() async {
    try {
      final p = await sb.from('profiles').select('last_seen_at').eq('id', widget.otherUserId).maybeSingle();
      if (!mounted) return;
      final raw = p?['last_seen_at'] as String?;
      final dt = raw == null ? null : DateTime.tryParse(raw);
      final online = dt != null && DateTime.now().toUtc().difference(dt.toUtc()).inSeconds < 100;
      setState(() {
        _otherOnline = online;
        if (online) {
          _otherStatus = 'online';
        } else if (dt != null) {
          final local = dt.toLocal();
          final now = DateTime.now();
          _otherStatus = DateUtils.isSameDay(local, now)
              ? 'last seen ${DateFormat('HH:mm').format(local)}'
              : 'last seen ${DateFormat('MMM d, HH:mm').format(local)}';
        } else {
          _otherStatus = '';
        }
      });
    } catch (_) {}
  }

  Future<void> _loadMuted() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    final row = await sb.from('conversation_members').select('muted')
        .eq('conversation_id', widget.conversationId).eq('user_id', me).maybeSingle();
    if (mounted) setState(() => _muted = row?['muted'] == true);
  }

  Future<void> _toggleMute() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    await sb.from('conversation_members').update({'muted': !_muted})
        .eq('conversation_id', widget.conversationId).eq('user_id', me);
    if (mounted) setState(() => _muted = !_muted);
  }

  Future<void> _setTyping(bool value) async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    try {
      await sb.from('typing_states').upsert({
        'conversation_id': widget.conversationId,
        'user_id': me,
        'is_typing': value,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'conversation_id,user_id');
    } catch (_) {}
  }

  void _onTyping(String text) {
    _typingStop?.cancel();
    if (text.trim().isEmpty) {
      if (_typingSent) {
        _typingSent = false;
        _setTyping(false);
      }
      return;
    }
    if (!_typingSent) {
      _typingSent = true;
      _setTyping(true);
    }
    _typingStop = Timer(const Duration(seconds: 2), () {
      _typingSent = false;
      _setTyping(false);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      }
    });
  }

  void _jumpToMessage(String id) {
    final index = _latestMessages.indexWhere((m) => m['id'].toString() == id);
    if (index < 0 || !_scroll.hasClients) return;
    final target = (index * 82.0).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
  }

  String _stamp(DateTime dt) {
    final l = dt.toLocal(), n = DateTime.now();
    if (DateUtils.isSameDay(l, n)) return DateFormat('HH:mm').format(l);
    if (DateUtils.isSameDay(l, n.subtract(const Duration(days: 1)))) return 'Yesterday ${DateFormat('HH:mm').format(l)}';
    return DateFormat('MMM d, HH:mm').format(l);
  }

  String _receipt(DateTime created) {
    if (_otherLastRead != null && !_otherLastRead!.isBefore(created)) return 'Read';
    if (_otherDelivered != null && !_otherDelivered!.isBefore(created)) return 'Delivered';
    return 'Sent';
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    final u = sb.auth.currentUser;
    if (text.isEmpty || u == null) return;
    setState(() => _sending = true);
    try {
      if (_editing != null) {
        await sb.from('messages').update({'body': text, 'edited_at': DateTime.now().toUtc().toIso8601String()}).eq('id', _editing!['id']);
      } else {
        await sb.from('messages').insert({
          'conversation_id': widget.conversationId,
          'sender_id': u.id,
          'body': text,
          'reply_to': _replyingTo?['id'],
        });
      }
      _input.clear();
      _setTyping(false);
      if (mounted) setState(() { _editing = null; _replyingTo = null; });
      _scrollToBottom();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deleteMessage(Map<String, dynamic> m) async {
    await sb.from('messages').update({
      'body': 'Message deleted',
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
      'edited_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', m['id']);
  }

  Future<void> _toggleReaction(Map<String, dynamic> m, String emoji) async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    final existing = await sb.from('message_reactions').select('emoji')
        .eq('message_id', m['id']).eq('user_id', me).eq('emoji', emoji).maybeSingle();
    if (existing != null) {
      await sb.from('message_reactions').delete().eq('message_id', m['id']).eq('user_id', me).eq('emoji', emoji);
    } else {
      await sb.from('message_reactions').insert({
        'message_id': m['id'],
        'conversation_id': widget.conversationId,
        'user_id': me,
        'emoji': emoji,
      });
    }
  }

  Future<void> _reactionPicker(Map<String, dynamic> m) async {
    final emoji = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('React'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: ['👍', '❤️', '😂', '😮', '😢', '💀'].map((e) => InkWell(
            onTap: () => Navigator.pop(ctx, e),
            child: Padding(padding: const EdgeInsets.all(8), child: Text(e, style: const TextStyle(fontSize: 28))),
          )).toList(),
        ),
      ),
    );
    if (emoji != null) await _toggleReaction(m, emoji);
  }

  Future<void> _pin(Map<String, dynamic> m) async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    await sb.from('conversation_pins').upsert({
      'conversation_id': widget.conversationId,
      'message_id': m['id'],
      'pinned_by': me,
      'pinned_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'conversation_id');
  }

  Future<void> _unpin() async {
    await sb.from('conversation_pins').delete().eq('conversation_id', widget.conversationId);
  }

  Future<void> _report(Map<String, dynamic> m) async {
    String reason = 'Harassment';
    final comment = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Report this message?'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('To help moderators review your report, the 5 messages immediately before the reported message will also be included as context. Only this context and the reported message will be shared with moderators.'),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: reason,
                items: const ['Harassment', 'Spam', 'Hate speech', 'Threats', 'Scam', 'Other']
                    .map((x) => DropdownMenuItem(value: x, child: Text(x))).toList(),
                onChanged: (v) => setD(() => reason = v ?? reason),
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
              const SizedBox(height: 12),
              TextField(controller: comment, maxLength: 1000, maxLines: 3, decoration: const InputDecoration(labelText: 'Additional comment (optional)', border: OutlineInputBorder())),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Submit report')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await sb.rpc('report_message', params: {'target_message': m['id'], 'report_reason': reason, 'report_comment': comment.text.trim()});
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report sent.')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Report failed: $e')));
      }
    }
    comment.dispose();
  }

  void _menu(Map<String, dynamic> m) {
    final mine = m['sender_id'] == sb.auth.currentUser?.id;
    final deleted = m['deleted_at'] != null;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          if (!deleted) ListTile(leading: const Icon(Icons.emoji_emotions_outlined), title: const Text('React'), onTap: () { Navigator.pop(ctx); _reactionPicker(m); }),
          if (!deleted) ListTile(leading: const Icon(Icons.push_pin_outlined), title: const Text('Pin'), onTap: () { Navigator.pop(ctx); _pin(m); }),
          if (!deleted) ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () { Navigator.pop(ctx); setState(() => _replyingTo = m); }),
          if (!deleted) ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () { Clipboard.setData(ClipboardData(text: (m['body'] ?? '').toString())); Navigator.pop(ctx); }),
          if (mine && !deleted) ListTile(leading: const Icon(Icons.edit), title: const Text('Edit'), onTap: () { Navigator.pop(ctx); setState(() => _editing = m); _input.text = (m['body'] ?? '').toString(); }),
          if (mine && !deleted) ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete'), onTap: () { Navigator.pop(ctx); _deleteMessage(m); }),
          if (!mine && !deleted) ListTile(leading: const Icon(Icons.flag_outlined), title: const Text('Report'), onTap: () { Navigator.pop(ctx); _report(m); }),
        ]),
      ),
    );
  }

  Future<void> _openSearch() async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => MessageSearchPage(conversationId: widget.conversationId)),
    );
    if (id != null) _jumpToMessage(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfilePage(userId: widget.otherUserId))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (_otherStatus.isNotEmpty)
              Text(_otherStatus, style: TextStyle(fontSize: 12, color: _otherOnline ? Colors.greenAccent : Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        actions: [
          IconButton(tooltip: 'Search messages', onPressed: _openSearch, icon: const Icon(Icons.search)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'mute') _toggleMute();
              if (v == 'profile') Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfilePage(userId: widget.otherUserId)));
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'mute', child: Text(_muted ? 'Unmute chat' : 'Mute chat')),
              const PopupMenuItem(value: 'profile', child: Text('View profile')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _pins,
          builder: (context, pinSnap) {
            final pins = pinSnap.data ?? const <Map<String, dynamic>>[];
            if (pins.isEmpty) return const SizedBox.shrink();
            final id = pins.first['message_id']?.toString();
            final matches = _latestMessages.where((m) => m['id'].toString() == id).toList();
            final Map<String, dynamic>? msg = matches.isEmpty ? null : matches.first;
            return Material(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.push_pin, size: 18),
                title: Text(msg == null ? 'Pinned message' : (msg['body'] ?? 'Pinned message').toString(), maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: id == null ? null : () => _jumpToMessage(id),
                trailing: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: _unpin),
              ),
            );
          },
        ),
        Expanded(
          child: StreamBuilder<List<Map<String, dynamic>>>(
            stream: _reactions,
            builder: (context, reactionSnapshot) {
              final reactionRows = reactionSnapshot.data ?? const <Map<String, dynamic>>[];
              final grouped = <String, Map<String, int>>{};
              for (final r in reactionRows) {
                final id = r['message_id'].toString();
                final emoji = r['emoji'].toString();
                grouped.putIfAbsent(id, () => <String, int>{});
                grouped[id]![emoji] = (grouped[id]![emoji] ?? 0) + 1;
              }
              return StreamBuilder<List<Map<String, dynamic>>>(
                stream: _messages,
                builder: (context, snapshot) {
                  if (snapshot.hasError) return Center(child: Text('Chat error: ${snapshot.error}'));
                  if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                  final messages = snapshot.data!;
                  _latestMessages = messages;
                  if (_lastMessageCount != messages.length) {
                    _lastMessageCount = messages.length;
                    _markRead();
                    _loadReceipt();
                    _scrollToBottom();
                  }
                  final byId = {for (final m in messages) m['id'].toString(): m};
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final m = messages[index];
                      final mine = m['sender_id'] == sb.auth.currentUser?.id;
                      final deleted = m['deleted_at'] != null;
                      final created = DateTime.tryParse((m['created_at'] ?? '').toString()) ?? DateTime.now();
                      final reply = byId[m['reply_to']?.toString()];
                      final rs = grouped[m['id'].toString()] ?? const <String, int>{};
                      return Align(
                        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: GestureDetector(
                          onLongPress: () => _menu(m),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .80),
                            decoration: BoxDecoration(
                              color: mine ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              if (reply != null)
                                GestureDetector(
                                  onTap: () => _jumpToMessage(reply['id'].toString()),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(7),
                                    margin: const EdgeInsets.only(bottom: 6),
                                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(8)),
                                    child: Text(reply['deleted_at'] != null ? 'Message deleted' : (reply['body'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
                                  ),
                                ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(deleted ? 'Message deleted' : (m['body'] ?? '').toString(), style: deleted ? const TextStyle(fontStyle: FontStyle.italic) : null),
                              ),
                              if (rs.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Wrap(
                                      spacing: 5,
                                      runSpacing: 4,
                                      children: rs.entries.map((e) => ActionChip(
                                        visualDensity: VisualDensity.compact,
                                        label: Text('${e.key} ${e.value}'),
                                        onPressed: () => _toggleReaction(m, e.key),
                                      )).toList(),
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 3),
                              Text('${_stamp(created)}${m['edited_at'] != null && !deleted ? '  • edited' : ''}${mine ? '  • ${_receipt(created)}' : ''}', style: Theme.of(context).textTheme.labelSmall),
                            ]),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _typing,
          builder: (context, snap) {
            final me = sb.auth.currentUser?.id;
            final now = DateTime.now().toUtc();
            final otherTyping = (snap.data ?? const <Map<String, dynamic>>[]).any((r) {
              final dt = DateTime.tryParse((r['updated_at'] ?? '').toString());
              return r['user_id'] != me && r['is_typing'] == true && dt != null && now.difference(dt.toUtc()).inSeconds < 5;
            });
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: otherTyping
                  ? const Padding(key: ValueKey('typing'), padding: EdgeInsets.fromLTRB(14, 2, 14, 4), child: Align(alignment: Alignment.centerLeft, child: Text('typing…', style: TextStyle(fontStyle: FontStyle.italic))))
                  : const SizedBox(key: ValueKey('not-typing'), height: 4),
            );
          },
        ),
        if (_replyingTo != null || _editing != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
            child: Row(children: [
              Expanded(child: Text(_editing != null ? 'Editing message' : 'Replying to: ${(_replyingTo?['body'] ?? '').toString()}', maxLines: 1, overflow: TextOverflow.ellipsis)),
              IconButton(onPressed: () { setState(() { _replyingTo = null; _editing = null; }); _input.clear(); }, icon: const Icon(Icons.close)),
            ]),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                onChanged: _onTyping,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(hintText: 'Message...', border: OutlineInputBorder()),
              )),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}


class MessageSearchPage extends StatefulWidget {
  final String conversationId;
  const MessageSearchPage({super.key, required this.conversationId});

  @override
  State<MessageSearchPage> createState() => _MessageSearchPageState();
}

class _MessageSearchPageState extends State<MessageSearchPage> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _busy = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(value));
  }

  Future<void> _search(String value) async {
    final q = value.trim();
    if (q.isEmpty) {
      if (mounted) setState(() => _results = []);
      return;
    }
    setState(() => _busy = true);
    try {
      final rows = await sb.from('messages')
          .select('id,body,created_at,sender_id,deleted_at')
          .eq('conversation_id', widget.conversationId)
          .isFilter('deleted_at', null)
          .ilike('body', '%$q%')
          .order('created_at', ascending: false)
          .limit(100);
      if (mounted) setState(() => _results = List<Map<String, dynamic>>.from(rows));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: TextField(controller: _q, autofocus: true, onChanged: _changed, decoration: const InputDecoration(hintText: 'Search in chat…', border: InputBorder.none))),
    body: _busy && _results.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, i) {
              final m = _results[i];
              final dt = DateTime.tryParse((m['created_at'] ?? '').toString());
              return ListTile(
                leading: Icon(m['sender_id'] == sb.auth.currentUser?.id ? Icons.call_made : Icons.call_received),
                title: Text((m['body'] ?? '').toString(), maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: dt == null ? null : Text(DateFormat('MMM d, yyyy • HH:mm').format(dt.toLocal())),
                onTap: () => Navigator.pop(context, m['id'].toString()),
              );
            },
          ),
  );
}

class UserProfilePage extends StatefulWidget {
  final String userId;
  const UserProfilePage({super.key, required this.userId});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _blockedByMe = false;
  bool _blockedMe = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    final profile = await sb.from('profiles').select('username,display_name,avatar_url,bio,role,verified,created_at,last_seen_at').eq('id', widget.userId).single();
    final mine = await sb.from('user_blocks').select('blocker_id').eq('blocker_id', me).eq('blocked_id', widget.userId).maybeSingle();
    final theirs = await sb.from('user_blocks').select('blocker_id').eq('blocker_id', widget.userId).eq('blocked_id', me).maybeSingle();
    if (mounted) setState(() { _profile = profile; _blockedByMe = mine != null; _blockedMe = theirs != null; _loading = false; });
  }

  Future<void> _toggleBlock() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    if (_blockedByMe) {
      await sb.from('user_blocks').delete().eq('blocker_id', me).eq('blocked_id', widget.userId);
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Block user?'),
          content: const Text('You will not be able to message each other until you unblock them.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Block')),
          ],
        ),
      );
      if (ok != true) return;
      await sb.from('user_blocks').insert({'blocker_id': me, 'blocked_id': widget.userId});
    }
    await _load();
  }

  String _lastSeen() {
    final raw = _profile?['last_seen_at'] as String?;
    final dt = raw == null ? null : DateTime.tryParse(raw);
    if (dt == null) return 'Last seen unavailable';
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inSeconds < 100) return 'Online';
    return 'Last seen ${DateFormat('MMM d, HH:mm').format(dt.toLocal())}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final p = _profile!;
    final username = (p['username'] ?? 'Unknown').toString();
    final display = (p['display_name'] ?? '').toString().trim();
    final avatarUrl = (p['avatar_url'] ?? '').toString().trim();
    final validAvatar = Uri.tryParse(avatarUrl)?.hasAbsolutePath == true && (avatarUrl.startsWith('http://') || avatarUrl.startsWith('https://'));
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(padding: const EdgeInsets.all(22), children: [
        Center(child: CircleAvatar(radius: 48, backgroundImage: validAvatar ? NetworkImage(avatarUrl) : null, child: validAvatar ? null : Text(username.isEmpty ? '?' : username[0].toUpperCase(), style: const TextStyle(fontSize: 32)))),
        const SizedBox(height: 14),
        Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(display.isEmpty ? '@$username' : display, style: Theme.of(context).textTheme.headlineSmall)),
          if (p['verified'] == true) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.verified, color: Colors.lightBlueAccent)),
        ])),
        Center(child: Text('@$username')),
        const SizedBox(height: 4),
        Center(child: Text(_lastSeen(), style: Theme.of(context).textTheme.bodySmall)),
        if (p['role'] == 'owner') const Padding(padding: EdgeInsets.only(top: 8), child: Center(child: Text('OWNER', style: TextStyle(fontWeight: FontWeight.bold)))),
        if ((p['bio'] ?? '').toString().trim().isNotEmpty) ...[
          const SizedBox(height: 22),
          Text((p['bio'] ?? '').toString(), textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        if (_blockedMe) const Card(child: ListTile(leading: Icon(Icons.block), title: Text('This user has blocked you.'))),
        OutlinedButton.icon(
          onPressed: _toggleBlock,
          icon: Icon(_blockedByMe ? Icons.lock_open : Icons.block),
          label: Text(_blockedByMe ? 'Unblock user' : 'Block user'),
        ),
      ]),
    );
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final display = TextEditingController(), bio = TextEditingController(), avatar = TextEditingController();
  Map<String, dynamic>? p;
  bool busy = true;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { display.dispose(); bio.dispose(); avatar.dispose(); super.dispose(); }

  Future<void> _load() async {
    final x = await sb.from('profiles').select('username,display_name,bio,avatar_url,role,verified,created_at,last_seen_at').eq('id', sb.auth.currentUser!.id).single();
    if (mounted) setState(() { p = x; display.text = (x['display_name'] ?? '').toString(); bio.text = (x['bio'] ?? '').toString(); avatar.text = (x['avatar_url'] ?? '').toString(); busy = false; });
  }

  Future<void> _save() async {
    await sb.from('profiles').update({
      'display_name': display.text.trim(),
      'bio': bio.text.trim(),
      'avatar_url': avatar.text.trim().isEmpty ? null : avatar.text.trim(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', sb.auth.currentUser!.id);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile saved.')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final avatarUrl = (p?['avatar_url'] ?? '').toString().trim();
    final validAvatar = avatarUrl.startsWith('http://') || avatarUrl.startsWith('https://');
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(20), children: [
              Center(child: CircleAvatar(radius: 42, backgroundImage: validAvatar ? NetworkImage(avatarUrl) : null, child: validAvatar ? null : Text((p?['username'] ?? '?').toString().substring(0, 1).toUpperCase()))),
              const SizedBox(height: 12),
              Center(child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('@${p?['username']}', style: Theme.of(context).textTheme.titleLarge),
                if (p?['verified'] == true) const Padding(padding: EdgeInsets.only(left: 5), child: Icon(Icons.verified, color: Colors.lightBlueAccent)),
                if (p?['role'] == 'owner') const Padding(padding: EdgeInsets.only(left: 8), child: Text('OWNER', style: TextStyle(fontWeight: FontWeight.bold))),
              ])),
              const SizedBox(height: 22),
              TextField(controller: display, decoration: const InputDecoration(labelText: 'Display name', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: bio, maxLength: 160, maxLines: 3, decoration: const InputDecoration(labelText: 'Bio', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: avatar, decoration: const InputDecoration(labelText: 'Avatar URL', border: OutlineInputBorder())),
              const SizedBox(height: 16),
              FilledButton(onPressed: _save, child: const Text('Save profile')),
              if (devBuild) ...[
                const SizedBox(height: 24),
                const Card(child: ListTile(leading: Icon(Icons.science_outlined), title: Text('DEV BUILD'), subtitle: Text('Temporary development signing is enabled for this build.'))),
              ],
            ]),
    );
  }
}


class AdminPage extends StatefulWidget { const AdminPage({super.key}); @override State<AdminPage> createState()=>_AdminPageState(); }
class _AdminPageState extends State<AdminPage>{
  List<Map<String,dynamic>> users=[],reports=[]; bool loading=true;
  @override void initState(){super.initState();_load();}
  Future<void> _load()async{try{final u=await sb.from('profiles').select('id,username,display_name,role,verified,created_at').order('created_at',ascending:false);final r=await sb.from('message_reports').select().order('created_at',ascending:false);if(mounted)setState((){users=List<Map<String,dynamic>>.from(u);reports=List<Map<String,dynamic>>.from(r);loading=false;});}catch(e){if(mounted){setState(()=>loading=false);ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Admin error: $e')));}}}
  Future<void> _verify(Map<String,dynamic> u)async{await sb.rpc('set_user_verified',params:{'target_user':u['id'],'new_value':u['verified']!=true});await _load();}
  Future<void> _status(Map<String,dynamic> r,String status)async{await sb.from('message_reports').update({'status':status}).eq('id',r['id']);await _load();}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Admin Panel')),body:loading?const Center(child:CircularProgressIndicator()):DefaultTabController(length:2,child:Column(children:[const TabBar(tabs:[Tab(text:'Reports'),Tab(text:'Users')]),Expanded(child:TabBarView(children:[ListView.builder(itemCount:reports.length,itemBuilder:(c,i){final r=reports[i];final ctx=(r['context'] as List?)??[];return ExpansionTile(title:Text('${r['reason']} • ${r['status']}'),subtitle:Text((r['reported_body']??'').toString(),maxLines:2,overflow:TextOverflow.ellipsis),children:[Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Context (up to 5 previous messages)',style:TextStyle(fontWeight:FontWeight.bold)),for(final x in ctx)Padding(padding:const EdgeInsets.symmetric(vertical:3),child:Text('• ${(x as Map)['body']}')),const Divider(),const Text('Reported message',style:TextStyle(fontWeight:FontWeight.bold)),Text((r['reported_body']??'').toString()),if((r['comment']??'').toString().isNotEmpty)...[const SizedBox(height:8),Text('Reporter comment: ${r['comment']}')],const SizedBox(height:10),Wrap(spacing:8,children:[OutlinedButton(onPressed:()=>_status(r,'dismissed'),child:const Text('Dismiss')),FilledButton(onPressed:()=>_status(r,'resolved'),child:const Text('Resolve'))])]))]);}),ListView.builder(itemCount:users.length,itemBuilder:(c,i){final u=users[i];return ListTile(title:Row(children:[Flexible(child:Text('@${u['username']}')),if(u['verified']==true)const Padding(padding:EdgeInsets.only(left:5),child:Icon(Icons.verified,size:18,color:Colors.lightBlueAccent)),if(u['role']=='owner')const Padding(padding:EdgeInsets.only(left:7),child:Text('OWNER',style:TextStyle(fontSize:10,fontWeight:FontWeight.bold)))]),subtitle:Text((u['display_name']??'').toString()),trailing:u['role']=='owner'?null:TextButton(onPressed:()=>_verify(u),child:Text(u['verified']==true?'Unverify':'Verify')));})]))])));
}
