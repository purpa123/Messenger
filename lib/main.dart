import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = 'https://vepgxpgasbkrloaaxgvh.supabase.co';
const supabasePublishableKey = 'sb_publishable_dIP2ZG4M85bRh771f4mh9A_DuSyGub4';

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
      debugShowCheckedModeBanner: false,
      title: 'Messenger',
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

  @override
  void initState() {
    super.initState();
    _loadChats();
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
            .select('username,display_name,role,verified')
            .eq('id', otherId)
            .maybeSingle();

        conversation['other_id'] = otherId;
        conversation['profile'] = profile;
        output.add(conversation);
      }
      output.sort((a, b) => (b['last_message_at'] ?? '').toString().compareTo((a['last_message_at'] ?? '').toString()));

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

          return ListTile(
            leading: CircleAvatar(child: Text(initial)),
            title: Row(children: [
              Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
              if (profile?['verified'] == true) ...[const SizedBox(width: 5), const Icon(Icons.verified, size: 18, color: Colors.lightBlueAccent)],
              if (profile?['role'] == 'owner') ...[const SizedBox(width: 5), const Text('OWNER', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold))],
            ]),
            subtitle: Text('@$username'),
            trailing: (chat['unread_count'] as num? ?? 0) > 0
                ? Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(20)), child: Text('${chat['unread_count']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))
                : null,
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ChatPage(
                    conversationId: chat['id'] as String,
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
        title: const Text('Messenger'),
        actions: [
          IconButton(
            onPressed: () => sb.auth.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SearchPage()),
          );
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
          .select('id,username,display_name,role,verified')
          .ilike('username', '%$query%')
          .neq('id', me)
          .limit(30);
      if (mounted) {
        setState(() => _results = List<Map<String, dynamic>>.from(rows));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Search failed: $e')),
        );
      }
    }
  }

  Future<void> _openChat(Map<String, dynamic> profile) async {
    if (_busy) return;
    final me = sb.auth.currentUser?.id;
    final other = profile['id'] as String?;
    if (me == null || other == null) return;

    setState(() => _busy = true);
    try {
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
              .insert({
                'created_by': me,
                'kind': 'dm',
                'dm_user_low': low,
                'dm_user_high': high,
              })
              .select('id')
              .single();
          conversationId = created['id'] as String;
        } on PostgrestException catch (e) {
          // Another client may have created the same unique DM at the same time.
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
        final memberIds = existingMembership
            .map((row) => row['user_id'] as String)
            .toSet();
        final missing = <Map<String, dynamic>>[];
        if (!memberIds.contains(me)) {
          missing.add({'conversation_id': conversationId, 'user_id': me});
        }
        if (!memberIds.contains(other)) {
          missing.add({'conversation_id': conversationId, 'user_id': other});
        }
        if (missing.isNotEmpty) {
          await sb.from('conversation_members').insert(missing);
        }
      }

      if (!mounted) return;
      final displayName = (profile['display_name'] ?? '').toString().trim();
      final username = (profile['username'] ?? 'Unknown').toString();
      final title = displayName.isEmpty ? '@$username' : displayName;

      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ChatPage(
            conversationId: conversationId,
            title: title,
          ),
        ),
      );
    } on PostgrestException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open chat: $e')),
        );
      }
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
          decoration: const InputDecoration(
            hintText: 'Search username...',
            border: InputBorder.none,
          ),
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
                title: Row(children: [
                  Flexible(child: Text(displayName.isEmpty ? '@$username' : displayName)),
                  if (profile['verified'] == true) ...[const SizedBox(width: 5), const Icon(Icons.verified, size: 18, color: Colors.lightBlueAccent)],
                  if (profile['role'] == 'owner') ...[const SizedBox(width: 5), const Text('OWNER', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold))],
                ]),
                subtitle: Text('@$username'),
                onTap: _busy ? null : () => _openChat(profile),
              );
            },
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x55000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  final String conversationId;
  final String title;

  const ChatPage({
    super.key,
    required this.conversationId,
    required this.title,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final Stream<List<Map<String, dynamic>>> _messages;
  bool _sending = false;
  DateTime? _otherLastRead;
  int _lastMessageCount = -1;

  @override
  void initState() {
    super.initState();
    _messages = sb.from('messages').stream(primaryKey: ['id']).eq('conversation_id', widget.conversationId).order('created_at');
    _markRead();
    _loadReceipt();
  }

  Future<void> _markRead() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    await sb.from('conversation_members').update({'last_read_at': DateTime.now().toUtc().toIso8601String()}).eq('conversation_id', widget.conversationId).eq('user_id', me);
  }

  Future<void> _loadReceipt() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    final rows = await sb.from('conversation_members').select('user_id,last_read_at').eq('conversation_id', widget.conversationId).neq('user_id', me);
    if (rows.isNotEmpty && mounted) {
      final raw = rows.first['last_read_at'] as String?;
      final next = raw == null ? null : DateTime.tryParse(raw);
      if (next != _otherLastRead) setState(() => _otherLastRead = next);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    });
  }

  @override
  void dispose() { _input.dispose(); _scroll.dispose(); super.dispose(); }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    final user = sb.auth.currentUser;
    if (text.isEmpty || user == null) return;
    setState(() => _sending = true);
    try {
      await sb.from('messages').insert({'conversation_id': widget.conversationId, 'sender_id': user.id, 'body': text});
      _input.clear();
      _scrollToBottom();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally { if (mounted) setState(() => _sending = false); }
  }

  String _stamp(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    if (DateUtils.isSameDay(local, now)) return DateFormat('HH:mm').format(local);
    if (DateUtils.isSameDay(local, now.subtract(const Duration(days: 1)))) return 'Yesterday ${DateFormat('HH:mm').format(local)}';
    return DateFormat('MMM d, HH:mm').format(local);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: Column(children: [
      Expanded(child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _messages,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('Chat error: ${snapshot.error}'));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final messages = snapshot.data!;
          if (_lastMessageCount != messages.length) {
            _lastMessageCount = messages.length;
            _markRead();
            _loadReceipt();
            _scrollToBottom();
          }
          return ListView.builder(
            controller: _scroll, padding: const EdgeInsets.all(12), itemCount: messages.length,
            itemBuilder: (context, index) {
              final message = messages[index];
              final mine = message['sender_id'] == sb.auth.currentUser?.id;
              final created = DateTime.tryParse((message['created_at'] ?? '').toString()) ?? DateTime.now();
              final delivered = mine && _otherLastRead != null && !_otherLastRead!.isBefore(created);
              return Align(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 3), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.80),
                  decoration: BoxDecoration(color: mine ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(18)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Align(alignment: Alignment.centerLeft, child: Text((message['body'] ?? '').toString())),
                    const SizedBox(height: 3),
                    Text('${_stamp(created)}${mine ? (delivered ? '  • Delivered' : '  • Sent') : ''}', style: Theme.of(context).textTheme.labelSmall),
                  ]),
                ),
              );
            },
          );
        },
      )),
      SafeArea(top: false, child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: TextField(controller: _input, minLines: 1, maxLines: 4, onSubmitted: (_) => _send(), decoration: const InputDecoration(hintText: 'Message...', border: OutlineInputBorder()))),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
        ]),
      )),
    ]),
  );
}
