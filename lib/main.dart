import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const supabaseUrl = 'https://vepgxpgasbkrloaaxgvh.supabase.co';
const supabasePublishableKey = 'sb_publishable_dIP2ZG4M85bRh771f4mh9A_DuSyGub4';
const devBuild = bool.fromEnvironment('DEV_BUILD', defaultValue: false);

const appBuildNumber = 17;
const appVersion = '0.7.2';


/// Purpa Messenger E2EE v1 (text messages).
/// Private X25519 material and cached conversation keys stay in Android Keystore-backed storage.
class E2eeService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static final _x25519 = X25519();
  static final _aes = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _rng = Random.secure();
  static String? _deviceRowId;
  static String? _deviceId;
  static SimpleKeyPairData? _deviceKeyPair;

  static List<int> _random(int n) => List<int>.generate(n, (_) => _rng.nextInt(256));
  static String _b64(List<int> v) => base64UrlEncode(v);
  static List<int> _unb64(String v) => base64Url.decode(v);

  static Future<void> ensureDevice() async {
    final user = sb.auth.currentUser;
    if (user == null) throw StateError('Not signed in');
    if (_deviceRowId != null && _deviceKeyPair != null) return;

    var did = await _storage.read(key: 'e2ee.device_id');
    if (did == null) {
      did = '${DateTime.now().microsecondsSinceEpoch}-${_b64(_random(12))}';
      await _storage.write(key: 'e2ee.device_id', value: did);
    }
    _deviceId = did;

    final privSaved = await _storage.read(key: 'e2ee.x25519.private');
    final pubSaved = await _storage.read(key: 'e2ee.x25519.public');
    SimpleKeyPairData kp;
    if (privSaved == null || pubSaved == null) {
      final generated = await _x25519.newKeyPair();
      final priv = await generated.extractPrivateKeyBytes();
      final pub = await generated.extractPublicKey();
      await _storage.write(key: 'e2ee.x25519.private', value: _b64(priv));
      await _storage.write(key: 'e2ee.x25519.public', value: _b64(pub.bytes));
      kp = SimpleKeyPairData(priv, publicKey: SimplePublicKey(pub.bytes, type: KeyPairType.x25519), type: KeyPairType.x25519);
    } else {
      final priv = _unb64(privSaved), pub = _unb64(pubSaved);
      kp = SimpleKeyPairData(priv, publicKey: SimplePublicKey(pub, type: KeyPairType.x25519), type: KeyPairType.x25519);
    }
    _deviceKeyPair = kp;
    final pub = await kp.extractPublicKey();
    final existing = await sb.from('e2ee_devices').select('id').eq('user_id', user.id).eq('device_id', did).maybeSingle();
    if (existing == null) {
      final row = await sb.from('e2ee_devices').insert({
        'user_id': user.id,
        'device_id': did,
        'identity_public_key': _b64(pub.bytes),
        'encryption_public_key': _b64(pub.bytes),
      }).select('id').single();
      _deviceRowId = row['id'].toString();
    } else {
      _deviceRowId = existing['id'].toString();
      await sb.from('e2ee_devices').update({'last_seen_at': DateTime.now().toUtc().toIso8601String()}).eq('id', _deviceRowId!);
    }
  }

  static Future<SecretKey> _wrapKeyFor(SimplePublicKey recipient, String conversationId) async {
    final shared = await _x25519.sharedSecretKey(keyPair: _deviceKeyPair!, remotePublicKey: recipient);
    return _hkdf.deriveKey(secretKey: shared, nonce: utf8.encode(conversationId), info: utf8.encode('purpa-messenger-e2ee-wrap-v1'));
  }

  static Future<SecretKey?> _loadConversationKey(String conversationId) async {
    final cached = await _storage.read(key: 'e2ee.conv.$conversationId.v1');
    if (cached != null) return SecretKey(_unb64(cached));
    await ensureDevice();
    final row = await sb.from('e2ee_conversation_keys').select('wrapped_key,nonce,sender_device_id')
        .eq('conversation_id', conversationId).eq('recipient_device_id', _deviceRowId!).eq('key_version', 1).maybeSingle();
    if (row == null) return null;
    final sender = await sb.from('e2ee_devices').select('encryption_public_key').eq('id', row['sender_device_id']).maybeSingle();
    if (sender == null) return null;
    final wrapKey = await _wrapKeyFor(SimplePublicKey(_unb64(sender['encryption_public_key'].toString()), type: KeyPairType.x25519), conversationId);
    final packed = jsonDecode(utf8.decode(_unb64(row['wrapped_key'].toString()))) as Map<String,dynamic>;
    final box = SecretBox(_unb64(packed['c'].toString()), nonce: _unb64(row['nonce'].toString()), mac: Mac(_unb64(packed['m'].toString())));
    final raw = await _aes.decrypt(box, secretKey: wrapKey);
    await _storage.write(key: 'e2ee.conv.$conversationId.v1', value: _b64(raw));
    return SecretKey(raw);
  }

  static Future<SecretKey> ensureConversationKey(String conversationId) async {
    await ensureDevice();
    final existing = await _loadConversationKey(conversationId);
    if (existing != null) {
      await _distributeConversationKey(conversationId, existing);
      return existing;
    }
    final raw = _random(32);
    final key = SecretKey(raw);
    await _storage.write(key: 'e2ee.conv.$conversationId.v1', value: _b64(raw));
    await _distributeConversationKey(conversationId, key);
    return key;
  }

  static Future<void> _distributeConversationKey(String conversationId, SecretKey key) async {
    await ensureDevice();
    final raw=await key.extractBytes();
    final members=await sb.from('conversation_members').select('user_id').eq('conversation_id',conversationId);
    final memberIds=members.map((x)=>x['user_id'].toString()).toList();
    if(memberIds.isEmpty)throw StateError('No conversation members');
    final devices=await sb.from('e2ee_devices').select('id,user_id,encryption_public_key').inFilter('user_id',memberIds).isFilter('revoked_at',null);
    if(!devices.any((d)=>d['id'].toString()==_deviceRowId))throw StateError('Current E2EE device missing');
    final existing=await sb.from('e2ee_conversation_keys').select('recipient_device_id').eq('conversation_id',conversationId).eq('key_version',1);
    final have=existing.map((x)=>x['recipient_device_id'].toString()).toSet();
    for(final d in devices){
      if(have.contains(d['id'].toString()))continue;
      final recipient=SimplePublicKey(_unb64(d['encryption_public_key'].toString()),type:KeyPairType.x25519);
      final wrapKey=await _wrapKeyFor(recipient,conversationId);
      final nonce=_random(12);
      final box=await _aes.encrypt(raw,secretKey:wrapKey,nonce:nonce);
      final packed=_b64(utf8.encode(jsonEncode({'c':_b64(box.cipherText),'m':_b64(box.mac.bytes)})));
      await sb.from('e2ee_conversation_keys').insert({'conversation_id':conversationId,'recipient_device_id':d['id'],'sender_device_id':_deviceRowId,'key_version':1,'wrapped_key':packed,'nonce':_b64(nonce)});
    }
  }

  static Future<Map<String,dynamic>> encryptText(String conversationId, String plaintext) async {
    final key = await ensureConversationKey(conversationId);
    final nonce = _random(12);
    final box = await _aes.encrypt(utf8.encode(plaintext), secretKey:key, nonce:nonce);
    return {
      'body':'🔒 Encrypted message',
      'encryption_version':1,
      'ciphertext':_b64(utf8.encode(jsonEncode({'c':_b64(box.cipherText),'m':_b64(box.mac.bytes)}))),
      'encryption_nonce':_b64(nonce),
      'sender_device_id':_deviceRowId,
      'key_version':1,
    };
  }

  static Future<Map<String,dynamic>> encryptAttachment(String conversationId, List<int> plaintext) async {
    final key = await ensureConversationKey(conversationId);
    final nonce = _random(12);
    final box = await _aes.encrypt(plaintext, secretKey:key, nonce:nonce);
    return {
      'bytes': box.cipherText,
      'nonce': _b64(nonce),
      'mac': _b64(box.mac.bytes),
      'version': 1,
    };
  }

  static Future<List<int>> decryptAttachment(String conversationId, List<int> ciphertext, String nonce, String mac) async {
    final key = await _loadConversationKey(conversationId);
    if (key == null) throw StateError('E2EE key unavailable');
    return _aes.decrypt(SecretBox(ciphertext, nonce:_unb64(nonce), mac:Mac(_unb64(mac))), secretKey:key);
  }

  static Future<Map<String,dynamic>> decryptMessage(Map<String,dynamic> original) async {
    final m=Map<String,dynamic>.from(original);
    if (m['encryption_version'] != 1 || m['ciphertext']==null || m['encryption_nonce']==null) return m;
    try {
      final key=await _loadConversationKey(m['conversation_id'].toString());
      if(key==null){m['body']='🔒 Encrypted message — key unavailable';return m;}
      final packed=jsonDecode(utf8.decode(_unb64(m['ciphertext'].toString()))) as Map<String,dynamic>;
      final box=SecretBox(_unb64(packed['c'].toString()),nonce:_unb64(m['encryption_nonce'].toString()),mac:Mac(_unb64(packed['m'].toString())));
      m['body']=utf8.decode(await _aes.decrypt(box,secretKey:key));
      m['_e2ee']=true;
    } catch (_) { m['body']='🔒 Unable to decrypt'; }
    return m;
  }
}


Future<void> _downloadAndInstallUpdate(BuildContext context, Uri uri, String expectedSha, int? expectedSize) async {
  BuildContext? progressContext;
  double progress=0;
  bool cancelled=false;
  final cancel=CancelToken();
  showDialog<void>(context:context,barrierDismissible:false,builder:(c){
    progressContext=c;
    return StatefulBuilder(builder:(c,setLocal)=>PopScope(canPop:false,child:AlertDialog(
      title:const Text('Downloading update'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        LinearProgressIndicator(value:progress==0?null:progress),
        const SizedBox(height:12),
        Text(progress==0?'Starting…':'${(progress*100).clamp(0,100).toStringAsFixed(0)}%'),
      ]),
      actions:[TextButton(onPressed:(){cancelled=true;cancel.cancel();Navigator.pop(c);},child:const Text('Cancel'))],
    )));
  });
  try{
    final dir=await getTemporaryDirectory();
    final file=File('${dir.path}/purpa-messenger-update.apk');
    await Dio().downloadUri(uri,file.path,cancelToken:cancel,onReceiveProgress:(got,total){
      if(total>0){progress=got/total;}
      if(progressContext!=null && progressContext!.mounted){
        // Rebuild dialog by notifying its route; progress text is secondary, system download still proceeds.
        (progressContext as Element).markNeedsBuild();
      }
    });
    if(cancelled)return;
    if(expectedSize!=null && expectedSize>0 && await file.length()!=expectedSize)throw Exception('Downloaded APK size does not match release metadata.');
    if(expectedSha.isNotEmpty){
      final digest=sha256.convert(await file.readAsBytes()).toString();
      if(digest.toLowerCase()!=expectedSha.toLowerCase())throw Exception('APK verification failed (SHA-256 mismatch).');
    }
    if(progressContext!=null && progressContext!.mounted)Navigator.pop(progressContext!);
    final result=await OpenFilex.open(file.path,type:'application/vnd.android.package-archive');
    if(result.type!=ResultType.done)throw Exception('Android Installer could not be opened: ${result.message}');
  }catch(e){
    if(progressContext!=null && progressContext!.mounted)Navigator.pop(progressContext!);
    if(context.mounted)showDialog(context:context,builder:(c)=>AlertDialog(title:const Text('Update failed'),content:Text('$e'),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('OK'))]));
  }
}

Future<void> checkForMessengerUpdate(BuildContext context, {bool manual=false}) async {
  try {
    final channel = devBuild ? 'dev' : 'stable';
    final raw = await sb.from('app_releases').select('version,build_number,severity,changelog,download_url,published_at,apk_sha256,apk_size_bytes').eq('channel',channel).eq('active',true).order('build_number',ascending:false).limit(1);
    if (raw.isEmpty) {
      if (manual && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('You are up to date.')));
      return;
    }
    final r = Map<String,dynamic>.from(raw.first);
    final remoteBuild = (r['build_number'] as num?)?.toInt() ?? 0;
    if (remoteBuild <= appBuildNumber) {
      if (manual && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('You are up to date.')));
      return;
    }
    if (!context.mounted) return;
    final severity=(r['severity']??'normal').toString();
    final critical=severity=='critical';
    final version=(r['version']??'New version').toString();
    final notes=(r['changelog']??'').toString();
    final url=(r['download_url']??'').toString();
    await showDialog<void>(
      context: context,
      barrierDismissible: !critical,
      builder:(ctx)=>PopScope(
        canPop: !critical,
        child: AlertDialog(
          icon:Icon(critical?Icons.warning_amber_rounded:Icons.system_update_alt),
          title:Text(critical?'Critical update required':'Update available — v$version'),
          content:SingleChildScrollView(child:Text(critical
            ? 'This update is required to continue using Purpa Messenger.${notes.isEmpty?'':'\n\nWhat’s new:\n$notes'}'
            : '${notes.isEmpty?'A new version of Purpa Messenger is available.':'What’s new:\n$notes'}')),
          actions:[
            if(!critical) TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Later')),
            FilledButton.icon(
              icon:const Icon(Icons.download_outlined),
              label:Text(critical?'Update now':'Update'),
              onPressed:() async {
                final uri=Uri.tryParse(url);
                if(uri==null || uri.scheme!='https'){return;}
                final choice=await showModalBottomSheet<String>(context:ctx,builder:(c)=>SafeArea(child:Wrap(children:[
                  const ListTile(title:Text('How do you want to update?')),
                  ListTile(leading:const Icon(Icons.auto_mode),title:const Text('Automatically'),subtitle:const Text('Download the APK in Messenger, verify it, then open Android Installer.'),onTap:()=>Navigator.pop(c,'auto')),
                  ListTile(leading:const Icon(Icons.open_in_browser),title:const Text('Manually'),subtitle:const Text('Open the download page in your browser.'),onTap:()=>Navigator.pop(c,'manual')),
                ])));
                if(choice=='manual'){await launchUrl(uri,mode:LaunchMode.externalApplication);return;}
                if(choice=='auto'){
                  await _downloadAndInstallUpdate(ctx,uri,(r['apk_sha256']??'').toString(),(r['apk_size_bytes'] as num?)?.toInt());
                }
              },
            ),
          ],
        ),
      ),
    );
  } catch (_) {
    if(manual && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Could not check for updates.')));
  }
}



final navigatorKey = GlobalKey<NavigatorState>();
final localNotifications = FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

Future<void> savePushToken(String? token) async {
  final me = sb.auth.currentUser?.id;
  if (me == null || token == null || token.isEmpty) return;
  try {
    await sb.from('push_tokens').upsert({
      'user_id': me,
      'token': token,
      'platform': 'android',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id,token');
  } catch (_) {}
}

Future<void> openPushConversation(RemoteMessage message) async {
  final conversationId = message.data['conversation_id'];
  if (conversationId == null || conversationId.toString().isEmpty) return;
  final me = sb.auth.currentUser?.id;
  if (me == null) return;
  try {
    final c = await sb.from('conversations')
        .select('dm_user_low,dm_user_high')
        .eq('id', conversationId.toString())
        .maybeSingle();
    if (c == null) return;
    final low = c['dm_user_low']?.toString();
    final high = c['dm_user_high']?.toString();
    final other = low == me ? high : low;
    if (other == null) return;
    final profile = await sb.from('profiles')
        .select('username,display_name')
        .eq('id', other)
        .maybeSingle();
    final title = (profile?['display_name'] ?? profile?['username'] ?? 'Chat').toString();
    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => ChatPage(
        conversationId: conversationId.toString(),
        otherUserId: other,
        title: title,
      )));
    }
  } catch (_) {}
}

Future<void> initPushNotifications() async {
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await localNotifications.initialize(
    const InitializationSettings(android: androidInit),
    onDidReceiveNotificationResponse: (response) async {
      final payload = response.payload;
      if (payload == null || payload.isEmpty) return;
      try {
        final data = Map<String, dynamic>.from(jsonDecode(payload));
        await openPushConversation(RemoteMessage(data: data));
      } catch (_) {}
    },
  );

  const channel = AndroidNotificationChannel(
    'messages',
    'Messages',
    description: 'New Purpa Messenger messages',
    importance: Importance.high,
  );
  await localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  final messaging = FirebaseMessaging.instance;
  await messaging.requestPermission(alert: true, badge: true, sound: true);
  await savePushToken(await messaging.getToken());
  messaging.onTokenRefresh.listen(savePushToken);

  FirebaseMessaging.onMessage.listen((message) async {
    final n = message.notification;
    final title = n?.title ?? message.data['title']?.toString() ?? 'Purpa Messenger';
    final body = n?.body ?? message.data['body']?.toString() ?? 'New message';
    await localNotifications.show(
      message.hashCode,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          channelDescription: 'New Purpa Messenger messages',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: jsonEncode(message.data),
    );
  });

  FirebaseMessaging.onMessageOpenedApp.listen(openPushConversation);
  final initial = await messaging.getInitialMessage();
  if (initial != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => openPushConversation(initial));
  }
}


SupabaseClient get sb => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabasePublishableKey,
  );
  await Firebase.initializeApp();
  runApp(const MessengerApp());
  await initPushNotifications();
}

class MessengerApp extends StatelessWidget {
  const MessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
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
    _subscription = sb.auth.onAuthStateChange.listen((_) async {
      if (sb.auth.currentSession != null) {
        await savePushToken(await FirebaseMessaging.instance.getToken());
      }
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
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => EmailOtpPage(email: _email.text.trim())));
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

class VerifyEmailGate extends StatelessWidget {
  const VerifyEmailGate({super.key});
  @override Widget build(BuildContext context) {
    final email=sb.auth.currentUser?.email;
    if(email==null)return const Scaffold(body:Center(child:Text('Email unavailable.')));
    return EmailOtpPage(email:email, signedInGate:true);
  }
}

class EmailOtpPage extends StatefulWidget {
  final String email;
  final bool signedInGate;
  const EmailOtpPage({super.key,required this.email,this.signedInGate=false});
  @override State<EmailOtpPage> createState()=>_EmailOtpPageState();
}
class _EmailOtpPageState extends State<EmailOtpPage>{
  final code=TextEditingController();
  bool busy=false; int cooldown=0; Timer? timer;
  @override void dispose(){timer?.cancel();code.dispose();super.dispose();}
  void snack(String x){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(x)));}
  Future<void> verify() async{
    final token=code.text.trim();
    if(token.length<6){snack('Enter the verification code from your email.');return;}
    setState(()=>busy=true);
    try{
      await sb.auth.verifyOTP(email:widget.email,token:token,type:OtpType.signup);
      if(!mounted)return;
      if(Navigator.canPop(context))Navigator.pop(context);
      else setState((){});
    }on AuthException catch(e){snack(e.message);}
    catch(e){snack('Verification failed: $e');}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> resend() async{
    if(cooldown>0)return;setState(()=>busy=true);
    try{
      await sb.auth.resend(type:OtpType.signup,email:widget.email);
      if(mounted){
        snack('A new verification code was sent.');
        setState(()=>cooldown=60);
        timer=Timer.periodic(const Duration(seconds:1),(t){
          if(!mounted)return;
          if(cooldown<=1){t.cancel();setState(()=>cooldown=0);}else setState(()=>cooldown--);
        });
      }
    }on AuthException catch(e){snack(e.message);}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:widget.signedInGate?null:AppBar(),
    body:Center(child:SingleChildScrollView(padding:const EdgeInsets.all(28),child:ConstrainedBox(
      constraints:const BoxConstraints(maxWidth:460),
      child:Column(mainAxisSize:MainAxisSize.min,children:[
        const Icon(Icons.password_rounded,size:68),
        const SizedBox(height:16),
        const Text('Verify your email',style:TextStyle(fontSize:26,fontWeight:FontWeight.bold)),
        const SizedBox(height:10),
        Text('Enter the verification code sent to ${widget.email}.',textAlign:TextAlign.center),
        const SizedBox(height:22),
        TextField(controller:code,keyboardType:TextInputType.number,maxLength:8,textAlign:TextAlign.center,
          decoration:const InputDecoration(labelText:'Verification code',border:OutlineInputBorder()),
          onSubmitted:(_)=>busy?null:verify()),
        const SizedBox(height:8),
        SizedBox(width:double.infinity,child:FilledButton(onPressed:busy?null:verify,child:Text(busy?'Checking…':'Verify'))),
        TextButton(onPressed:busy||cooldown>0?null:resend,child:Text(cooldown>0?'Resend code in ${cooldown}s':'Resend code')),
        if(widget.signedInGate)TextButton(onPressed:busy?null:()=>sb.auth.signOut(),child:const Text('Sign out')),
      ]),
    ))),
  );
}

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

    if (sb.auth.currentUser?.emailConfirmedAt == null) return const VerifyEmailGate();

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
  String _chatFilter = 'all';
  Timer? _heartbeat;
  Timer? _updateTimer;

  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) checkForMessengerUpdate(context); });
    _updateTimer = Timer.periodic(const Duration(hours: 6), (_) { if (mounted) checkForMessengerUpdate(context); });
    super.initState();
    _touchPresence();
    _heartbeat = Timer.periodic(const Duration(seconds: 45), (_) => _touchPresence());
    _loadChats();
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
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
            .select('muted,archived,favorite,marked_unread_at')
            .eq('conversation_id', conversation['id'])
            .eq('user_id', me)
            .maybeSingle();

        conversation['other_id'] = otherId;
        conversation['profile'] = profile;
        conversation['muted'] = membership?['muted'] == true;
        conversation['archived'] = membership?['archived'] == true;
        conversation['favorite'] = membership?['favorite'] == true;
        conversation['marked_unread_at'] = membership?['marked_unread_at'];
        output.add(conversation);

        await sb.from('conversation_members').update({
          'delivered_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('conversation_id', conversation['id']).eq('user_id', me);
      }
      output.sort((a, b) {
        final fav = (b['favorite'] == true ? 1 : 0) - (a['favorite'] == true ? 1 : 0);
        if (fav != 0) return fav;
        return (b['last_message_at'] ?? '').toString().compareTo((a['last_message_at'] ?? '').toString());
      });

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
      final visibleChats = _chats.where((c) {
        final unread = (c['unread_count'] as num? ?? 0) > 0 || c['marked_unread_at'] != null;
        if (_chatFilter == 'unread') return unread && c['archived'] != true;
        if (_chatFilter == 'archived') return c['archived'] == true;
        return c['archived'] != true;
      }).toList();
      body = Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12,8,12,4),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value:'all',label:Text('All')),
              ButtonSegment(value:'unread',label:Text('Unread')),
              ButtonSegment(value:'archived',label:Text('Archived')),
            ],
            selected: {_chatFilter},
            onSelectionChanged: (v)=>setState(()=>_chatFilter=v.first),
          ),
        ),
        Expanded(child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: visibleChats.length,
        itemBuilder: (context, index) {
          final chat = visibleChats[index];
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
            onLongPress: () async {
              final me = sb.auth.currentUser?.id;
              if (me == null) return;
              final action = await showModalBottomSheet<String>(
                context: context,
                builder: (ctx) => SafeArea(child: Wrap(children:[
                  ListTile(leading:Icon(chat['favorite']==true?Icons.star:Icons.star_border),title:Text(chat['favorite']==true?'Remove from favorites':'Add to favorites'),onTap:()=>Navigator.pop(ctx,'favorite')),
                  ListTile(leading:const Icon(Icons.mark_email_unread_outlined),title:const Text('Mark as unread'),onTap:()=>Navigator.pop(ctx,'unread')),
                  ListTile(leading:Icon(chat['archived']==true?Icons.unarchive_outlined:Icons.archive_outlined),title:Text(chat['archived']==true?'Unarchive':'Archive'),onTap:()=>Navigator.pop(ctx,'archive')),
                ])),
              );
              if (action == null) return;
              final patch=<String,dynamic>{};
              if(action=='favorite') patch['favorite']=chat['favorite']!=true;
              if(action=='archive') patch['archived']=chat['archived']!=true;
              if(action=='unread') patch['marked_unread_at']=DateTime.now().toUtc().toIso8601String();
              await sb.from('conversation_members').update(patch).eq('conversation_id',chat['id']).eq('user_id',me);
              await _loadChats();
            },
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
      )),
      ]);
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
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage())),
            icon: const Icon(Icons.settings_outlined),
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
  final Set<String> _selected = {};
  bool _selecting = false;
  bool _showBottom = false;
  int _newBelow = 0;
  bool _readReceiptsEnabled = true;

  @override
  void initState() {
    super.initState();
    _messages = sb.from('messages').stream(primaryKey: ['id']).eq('conversation_id', widget.conversationId).order('created_at', ascending: true).asyncMap((rows) async => Future.wait(rows.map(E2eeService.decryptMessage)));
    E2eeService.ensureDevice().then((_) { if(mounted)setState((){}); }).catchError((_){ });
    _typing = sb.from('typing_states').stream(primaryKey: ['conversation_id', 'user_id']).eq('conversation_id', widget.conversationId);
    _reactions = sb.from('message_reactions').stream(primaryKey: ['message_id', 'user_id', 'emoji']).eq('conversation_id', widget.conversationId);
    _pins = sb.from('conversation_pins').stream(primaryKey: ['conversation_id']).eq('conversation_id', widget.conversationId);
    _markRead();
    _loadReceipt();
    _loadOtherPresence();
    _loadMuted();
    _loadDraft();
    _loadChatPreferences();
    _scroll.addListener(_onScroll);
    _input.addListener(_saveDraftDebounced);
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
    _saveDraftNow();
    _input.removeListener(_saveDraftDebounced);
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Timer? _draftTimer;
  void _saveDraftDebounced() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 500), _saveDraftNow);
  }
  Future<void> _loadDraft() async {
    final me=sb.auth.currentUser?.id; if(me==null)return;
    try {
      final row=await sb.from('message_drafts').select('body').eq('conversation_id',widget.conversationId).eq('user_id',me).maybeSingle();
      if(row!=null && _input.text.isEmpty){_input.text=(row['body']??'').toString();}
    } catch(_){}
  }
  Future<void> _saveDraftNow() async {
    final me=sb.auth.currentUser?.id; if(me==null)return;
    try {
      final body=_input.text;
      if(body.trim().isEmpty){
        await sb.from('message_drafts').delete().eq('conversation_id',widget.conversationId).eq('user_id',me);
      } else {
        await sb.from('message_drafts').upsert({'conversation_id':widget.conversationId,'user_id':me,'body':body,'updated_at':DateTime.now().toUtc().toIso8601String()},onConflict:'conversation_id,user_id');
      }
    } catch(_){}
  }
  Future<void> _loadChatPreferences() async {
    final me=sb.auth.currentUser?.id; if(me==null)return;
    try {
      final row=await sb.from('profiles').select('read_receipts_enabled').eq('id',me).maybeSingle();
      if(mounted)setState(()=>_readReceiptsEnabled=row?['read_receipts_enabled']!=false);
    } catch(_){}
  }
  void _onScroll(){
    if(!_scroll.hasClients)return;
    final away=_scroll.position.maxScrollExtent-_scroll.position.pixels>180;
    if(away!=_showBottom && mounted)setState(()=>_showBottom=away);
    if(!away && _newBelow!=0 && mounted)setState(()=>_newBelow=0);
  }
  Future<void> _clearForMe() async {
    final me=sb.auth.currentUser?.id;if(me==null)return;
    await sb.from('conversation_members').update({'cleared_before':DateTime.now().toUtc().toIso8601String()}).eq('conversation_id',widget.conversationId).eq('user_id',me);
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('History cleared for you.')));
  }
  Future<void> _forwardMessages(List<Map<String,dynamic>> items) async {
    final me=sb.auth.currentUser?.id;if(me==null||items.isEmpty)return;
    final inbox=await sb.rpc('get_my_dm_inbox');
    if(!mounted)return;
    final choice=await showDialog<String>(context:context,builder:(ctx)=>SimpleDialog(title:const Text('Forward to'),children:[
      for(final raw in inbox) SimpleDialogOption(onPressed:()=>Navigator.pop(ctx,raw['conversation_id'].toString()),child:Text('Conversation ${raw['conversation_id'].toString().substring(0,8)}…'))
    ]));
    if(choice==null)return;
    for(final m in items){
      if(m['deleted_at']!=null)continue;
      await sb.from('messages').insert({'conversation_id':choice,'sender_id':me,'body':(m['body']??'').toString(),'message_type':'text','forwarded_from':m['id']});
    }
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('${items.length} message(s) forwarded.')));
  }
  Future<void> _bulkDelete() async {
    final me=sb.auth.currentUser?.id;if(me==null)return;
    final mine=_latestMessages.where((m)=>_selected.contains(m['id'].toString())&&m['sender_id']==me).toList();
    for(final m in mine){await _deleteMessage(m);}
    if(mounted)setState((){_selected.clear();_selecting=false;});
  }
  void _bulkCopy(){
    final items=_latestMessages.where((m)=>_selected.contains(m['id'].toString())).map((m)=>(m['body']??'').toString()).where((x)=>x.isNotEmpty).join('\n');
    Clipboard.setData(ClipboardData(text:items));
    setState((){_selected.clear();_selecting=false;});
  }
  Future<void> _markRead() async {
    final me = sb.auth.currentUser?.id;
    if (me == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      final patch=<String,dynamic>{'delivered_at':now,'marked_unread_at':null};
      if(_readReceiptsEnabled) patch['last_read_at']=now;
      await sb.from('conversation_members').update(patch)
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

  Future<void> _pickPhoto() async {
    final me=sb.auth.currentUser; if(me==null||_sending)return;
    final picked=await ImagePicker().pickImage(source:ImageSource.gallery,imageQuality:88,maxWidth:2560,maxHeight:2560);
    if(picked==null)return;
    final bytes=await picked.readAsBytes();
    if(bytes.length>10*1024*1024){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Photo must be 10 MB or smaller.')));return;}
    setState(()=>_sending=true);
    try{
      final ext=picked.name.toLowerCase().endsWith('.png')?'png':picked.name.toLowerCase().endsWith('.webp')?'webp':'jpg';
      final mime=ext=='png'?'image/png':ext=='webp'?'image/webp':'image/jpeg';
      final encryptedPhoto=await E2eeService.encryptAttachment(widget.conversationId,bytes);
      final path='${widget.conversationId}/${DateTime.now().microsecondsSinceEpoch}_${me.id}.e2ee';
      await sb.storage.from('message-images').uploadBinary(path,encryptedPhoto['bytes'] as List<int>,fileOptions:const FileOptions(contentType:'application/octet-stream',upsert:false));
      final caption=_input.text.trim();
      final captionFields=caption.isEmpty ? <String,dynamic>{'body':''} : await E2eeService.encryptText(widget.conversationId,caption);
      final insertedPhoto = await sb.from('messages').insert({
        'conversation_id':widget.conversationId,'sender_id':me.id,...captionFields,
        'message_type':'image','attachment_path':path,'attachment_mime':mime,'attachment_size':bytes.length,
        'attachment_encryption_version':1,'attachment_nonce':encryptedPhoto['nonce'],'attachment_mac':encryptedPhoto['mac'],
        'sender_device_id':E2eeService._deviceRowId,'key_version':1,'reply_to':_replyingTo?['id']
      }).select('id').single();
      try {
        await sb.functions.invoke('send-message-push', body: {
          'conversation_id': widget.conversationId,
          'message_id': insertedPhoto['id'],
        });
      } catch (_) {}
      _input.clear();if(mounted)setState(()=>_replyingTo=null);_scrollToBottom();
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Photo upload failed: $e')));}
    finally{if(mounted)setState(()=>_sending=false);}
  }

  Future<Uint8List?> _imageBytes(Map<String,dynamic> m) async {
    try {
      final path=m['attachment_path']?.toString(); if(path==null)return null;
      if(m['attachment_encryption_version']==1 && m['attachment_nonce']!=null && m['attachment_mac']!=null){
        final cipher=await sb.storage.from('message-images').download(path);
        final plain=await E2eeService.decryptAttachment(widget.conversationId,cipher,m['attachment_nonce'].toString(),m['attachment_mac'].toString());
        return Uint8List.fromList(plain);
      }
      final legacy=await sb.storage.from('message-images').download(path);
      return Uint8List.fromList(legacy);
    } catch(_){return null;}
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    final u = sb.auth.currentUser;
    if (text.isEmpty || u == null) return;
    setState(() => _sending = true);
    try {
      if (_editing != null) {
        final encrypted=await E2eeService.encryptText(widget.conversationId,text);
        await sb.from('messages').update({...encrypted, 'edited_at': DateTime.now().toUtc().toIso8601String()}).eq('id', _editing!['id']);
      } else {
        final encrypted=await E2eeService.encryptText(widget.conversationId,text);
        final insertedMessage = await sb.from('messages').insert({
          'conversation_id': widget.conversationId,
          'sender_id': u.id,
          ...encrypted,
          'reply_to': _replyingTo?['id'],
        }).select('id').single();
      try {
        await sb.functions.invoke('send-message-push', body: {
          'conversation_id': widget.conversationId,
          'message_id': insertedMessage['id'],
        });
      } catch (_) {
        // The message is already sent; a push failure must not block chat delivery.
      }
      }
      _input.clear();
      await _saveDraftNow();
      _setTyping(false);
      if (mounted) setState(() { _editing = null; _replyingTo = null; });
      _scrollToBottom();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _messageActions(Map<String,dynamic> m) async {
    final me=sb.auth.currentUser?.id;
    final mine=m['sender_id']==me;
    final deleted=m['deleted_at']!=null;
    final action=await showModalBottomSheet<String>(
      context:context,
      builder:(ctx)=>SafeArea(child:Wrap(children:[
        ListTile(leading:const Icon(Icons.reply),title:const Text('Reply'),onTap:()=>Navigator.pop(ctx,'reply')),
        if(!deleted)ListTile(leading:const Icon(Icons.copy),title:const Text('Copy'),onTap:()=>Navigator.pop(ctx,'copy')),
        if(mine&&!deleted)ListTile(leading:const Icon(Icons.edit_outlined),title:const Text('Edit'),onTap:()=>Navigator.pop(ctx,'edit')),
        if(!mine&&!deleted)ListTile(leading:const Icon(Icons.flag_outlined),title:const Text('Report'),onTap:()=>Navigator.pop(ctx,'report')),
        if(mine&&!deleted)ListTile(leading:const Icon(Icons.delete_outline),title:const Text('Delete'),onTap:()=>Navigator.pop(ctx,'delete')),
        ListTile(leading:const Icon(Icons.checklist),title:const Text('Select messages'),onTap:()=>Navigator.pop(ctx,'select')),
      ])),
    );
    if(!mounted||action==null)return;
    if(action=='reply'){setState(()=>_replyingTo=m);return;}
    if(action=='copy'){await Clipboard.setData(ClipboardData(text:(m['body']??'').toString()));return;}
    if(action=='edit'){setState((){_editing=m;_replyingTo=null;_input.text=(m['body']??'').toString();_input.selection=TextSelection.collapsed(offset:_input.text.length);});return;}
    if(action=='report'){await _report(m);return;}
    if(action=='select'){setState((){_selecting=true;_selected.add(m['id'].toString());});return;}
    if(action=='delete'){
      final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(
        title:const Text('Delete message?'),
        content:const Text('This message will be shown as deleted.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Delete'))],
      ));
      if(ok==true)await _deleteMessage(m);
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
        if (m['_e2ee'] == true) {
          // E2EE evidence is disclosed voluntarily by the reporter's device.
          // Supabase/moderators never receive the conversation key.
          final targetIndex = _latestMessages.indexWhere((x) => x['id'].toString() == m['id'].toString());
          if (targetIndex < 0) throw StateError('Reported message is no longer available locally');
          final start = max(0, targetIndex - 5);
          final previous = _latestMessages.sublist(start, targetIndex);
          final contextEvidence = previous.map((x) => {
            'message_id': x['id']?.toString(),
            'sender_id': x['sender_id']?.toString(),
            'body': (x['body'] ?? '').toString(),
            'created_at': x['created_at']?.toString(),
            'e2ee': x['_e2ee'] == true,
          }).toList();
          await sb.rpc('report_e2ee_message', params: {
            'target_message': m['id'],
            'report_reason': reason,
            'report_comment': comment.text.trim(),
            'decrypted_reported_body': (m['body'] ?? '').toString(),
            'decrypted_context': contextEvidence,
          });
        } else {
          await sb.rpc('report_message', params: {'target_message': m['id'], 'report_reason': reason, 'report_comment': comment.text.trim()});
        }
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Report sent.')));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Report failed: $e')));
      }
    }
    comment.dispose();
  }

  // ignore: unused_element
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
          if (!deleted) ListTile(leading: const Icon(Icons.forward_outlined), title: const Text('Forward'), onTap: () { Navigator.pop(ctx); _forwardMessages([m]); }),
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
            Text('🔒 ${widget.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
            if (_otherStatus.isNotEmpty)
              Text(_otherStatus, style: TextStyle(fontSize: 12, color: _otherOnline ? Colors.greenAccent : Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        actions: _selecting ? [
          Center(child:Padding(padding:const EdgeInsets.symmetric(horizontal:8),child:Text('${_selected.length}'))),
          IconButton(tooltip:'Copy',onPressed:_selected.isEmpty?null:_bulkCopy,icon:const Icon(Icons.copy)),
          IconButton(tooltip:'Forward',onPressed:_selected.isEmpty?null:() async {final items=_latestMessages.where((m)=>_selected.contains(m['id'].toString())).toList();await _forwardMessages(items);if(mounted)setState((){_selected.clear();_selecting=false;});},icon:const Icon(Icons.forward_outlined)),
          IconButton(tooltip:'Delete my selected messages',onPressed:_selected.isEmpty?null:_bulkDelete,icon:const Icon(Icons.delete_outline)),
          IconButton(tooltip:'Cancel',onPressed:()=>setState((){_selected.clear();_selecting=false;}),icon:const Icon(Icons.close)),
        ] : [
          IconButton(tooltip: 'Search messages', onPressed: _openSearch, icon: const Icon(Icons.search)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'mute') _toggleMute();
              if (v == 'profile') Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfilePage(userId: widget.otherUserId)));
              if (v == 'clear') _clearForMe();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'mute', child: Text(_muted ? 'Unmute chat' : 'Mute chat')),
              const PopupMenuItem(value: 'clear', child: Text('Clear history for me')),
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
                    if(_scroll.hasClients && _scroll.position.maxScrollExtent-_scroll.position.pixels>180){
                      _newBelow++;
                    } else {
                      _scrollToBottom();
                    }
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
                        child: Dismissible(
                          key: ValueKey('swipe-${m['id']}'),
                          direction: DismissDirection.startToEnd,
                          confirmDismiss: (_) async { if(!deleted)setState(()=>_replyingTo=m); return false; },
                          background: const Align(alignment:Alignment.centerLeft,child:Padding(padding:EdgeInsets.only(left:18),child:Icon(Icons.reply))),
                          child: GestureDetector(
                          onTap: _selecting ? () => setState(() {final id=m['id'].toString();if(!_selected.add(id))_selected.remove(id);if(_selected.isEmpty)_selecting=false;}) : null,
                          onLongPress: () { if(_selecting){setState(()=>_selected.add(m['id'].toString()));}else{_messageActions(m);} },
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
                              if (!deleted && m['message_type']=='image' && m['attachment_path']!=null)
                                FutureBuilder<Uint8List?>(future:_imageBytes(m),builder:(context,img)=>img.connectionState!=ConnectionState.done?const SizedBox(width:180,height:120,child:Center(child:CircularProgressIndicator())):img.data==null?const SizedBox(width:180,height:120,child:Center(child:Icon(Icons.broken_image))):GestureDetector(onTap:()=>showDialog(context:context,barrierColor:Colors.black87,builder:(dialogContext)=>Dialog.fullscreen(backgroundColor:Colors.black,child:SafeArea(child:Stack(children:[
                                  Positioned.fill(child:InteractiveViewer(
                                    minScale:1,
                                    maxScale:5,
                                    boundaryMargin:const EdgeInsets.all(80),
                                    clipBehavior:Clip.none,
                                    child:Center(child:Image.memory(img.data!,fit:BoxFit.contain,gaplessPlayback:true)),
                                  )),
                                  Positioned(top:8,right:8,child:IconButton(onPressed:()=>Navigator.pop(dialogContext),icon:const Icon(Icons.close,color:Colors.white))),
                                ])))),child:ClipRRect(borderRadius:BorderRadius.circular(12),child:Image.memory(img.data!,width:260,fit:BoxFit.cover,gaplessPlayback:true))),)),
                              if ((m['body']??'').toString().isNotEmpty || deleted)
                                Align(alignment:Alignment.centerLeft,child:Text(deleted?'Message deleted':(m['body']??'').toString(),style:deleted?const TextStyle(fontStyle:FontStyle.italic):null)),
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
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
        if (_showBottom)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right:12,bottom:4),
              child: FilledButton.tonalIcon(
                onPressed:(){_scrollToBottom();setState(()=>_newBelow=0);},
                icon:const Icon(Icons.keyboard_arrow_down),
                label:Text(_newBelow>0?'$_newBelow new':'Latest'),
              ),
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
              IconButton(tooltip:'Attach photo',onPressed:_sending?null:_pickPhoto,icon:const Icon(Icons.add_photo_alternate_outlined)),
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



class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override State<SettingsPage> createState()=>_SettingsPageState();
}
class _SettingsPageState extends State<SettingsPage>{
  bool _readReceipts=true;
  String _lastSeen='everyone';
  double _textScale=1.0;
  bool _busy=true;
  @override void initState(){super.initState();_load();}
  Future<void> _load() async {
    final me=sb.auth.currentUser?.id;if(me==null)return;
    try{
      final p=await sb.from('profiles').select('read_receipts_enabled,last_seen_visibility').eq('id',me).single();
      if(mounted)setState((){_readReceipts=p['read_receipts_enabled']!=false;_lastSeen=(p['last_seen_visibility']??'everyone').toString();_busy=false;});
    }catch(_){if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _save(Map<String,dynamic> patch) async {
    final me=sb.auth.currentUser?.id;if(me==null)return;
    await sb.from('profiles').update(patch).eq('id',me);
  }
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Settings')),
    body:_busy?const Center(child:CircularProgressIndicator()):ListView(children:[
      const ListTile(title:Text('Privacy',style:TextStyle(fontWeight:FontWeight.bold))),
      SwitchListTile(title:const Text('Read receipts'),subtitle:const Text('Let people see when you read messages'),value:_readReceipts,onChanged:(v){setState(()=>_readReceipts=v);_save({'read_receipts_enabled':v});}),
      ListTile(title:const Text('Last seen'),subtitle:Text(_lastSeen=='nobody'?'Nobody':'Everyone'),trailing:DropdownButton<String>(value:_lastSeen,items:const [DropdownMenuItem(value:'everyone',child:Text('Everyone')),DropdownMenuItem(value:'nobody',child:Text('Nobody'))],onChanged:(v){if(v==null)return;setState(()=>_lastSeen=v);_save({'last_seen_visibility':v});})),
      const Divider(),
      const ListTile(title:Text('Notifications',style:TextStyle(fontWeight:FontWeight.bold))),
      const ListTile(leading:Icon(Icons.notifications_outlined),title:Text('Chat notifications'),subtitle:Text('Per-chat mute is available from each conversation. Push delivery will be enabled when the notification service is connected.')),
      const Divider(),
      const ListTile(title:Text('Appearance',style:TextStyle(fontWeight:FontWeight.bold))),
      ListTile(title:const Text('Text size'),subtitle:Slider(value:_textScale,min:.85,max:1.35,divisions:10,label:'${(_textScale*100).round()}%',onChanged:(v)=>setState(()=>_textScale=v))),
      const Divider(),
      const ListTile(title:Text('Security',style:TextStyle(fontWeight:FontWeight.bold))),
      ListTile(leading:const Icon(Icons.logout),title:const Text('Log out from this device'),onTap:()async{await sb.auth.signOut();if(mounted)Navigator.pop(context);}),
      ListTile(leading:const Icon(Icons.phonelink_erase),title:const Text('Log out from all other sessions'),onTap:()async{await sb.auth.signOut(scope:SignOutScope.others);if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Other sessions signed out.')));}),
      ListTile(leading:const Icon(Icons.logout_outlined),title:const Text('Log out from all sessions'),onTap:()async{final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('Log out everywhere?'),content:const Text('All active sessions for this account will be signed out.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('Log out'))]));if(ok==true)await sb.auth.signOut(scope:SignOutScope.global);}),
      const Divider(),
      const ListTile(title:Text('About',style:TextStyle(fontWeight:FontWeight.bold))),
      ListTile(leading:const Icon(Icons.system_update_alt),title:const Text('Check for updates'),subtitle:Text('Current version $appVersion'),onTap:()=>checkForMessengerUpdate(context,manual:true)),
      const ListTile(title:Text('Purpa Messenger'),subtitle:Text('v0.5.2 QoL update')),
    ]),
  );
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
  final display = TextEditingController(), bio = TextEditingController(), avatar = TextEditingController(), status = TextEditingController();
  Map<String, dynamic>? p;
  bool busy = true;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { display.dispose(); bio.dispose(); avatar.dispose(); status.dispose(); super.dispose(); }

  Future<void> _load() async {
    final x = await sb.from('profiles').select('username,display_name,bio,avatar_url,role,verified,created_at,last_seen_at,custom_status').eq('id', sb.auth.currentUser!.id).single();
    if (mounted) setState(() { p = x; display.text = (x['display_name'] ?? '').toString(); bio.text = (x['bio'] ?? '').toString(); avatar.text = (x['avatar_url'] ?? '').toString(); status.text=(x['custom_status']??'').toString(); busy = false; });
  }

  Future<void> _save() async {
    await sb.from('profiles').update({
      'display_name': display.text.trim(),
      'bio': bio.text.trim(),
      'avatar_url': avatar.text.trim().isEmpty ? null : avatar.text.trim(),
      'custom_status': status.text.trim(),
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
              const SizedBox(height:12),
              TextField(controller:status,maxLength:80,decoration:const InputDecoration(labelText:'Custom status',border:OutlineInputBorder())),
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
  List<Map<String,dynamic>> users=[],reports=[]; bool loading=true; String userQuery='';
  @override void initState(){super.initState();_load();}
  Future<void> _load()async{try{final u=await sb.from('profiles').select('id,username,display_name,role,verified,created_at,suspended_until,muted_until').order('created_at',ascending:false);final r=await sb.from('message_reports').select().order('created_at',ascending:false);if(mounted)setState((){users=List<Map<String,dynamic>>.from(u);reports=List<Map<String,dynamic>>.from(r);loading=false;});}catch(e){if(mounted){setState(()=>loading=false);ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Admin error: $e')));}}}
  Future<void> _verify(Map<String,dynamic> u)async{await sb.rpc('set_user_verified',params:{'target_user':u['id'],'new_value':u['verified']!=true});await _load();}
  Future<void> _status(Map<String,dynamic> r,String status)async{await sb.from('message_reports').update({'status':status}).eq('id',r['id']);await _load();}
  Future<void> _moderate(String uid,String action,{String? reportId}) async {
    final reason=TextEditingController(); String duration='1d';
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setLocal)=>AlertDialog(title:Text(action.toUpperCase()),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:reason,maxLines:3,decoration:const InputDecoration(labelText:'Reason',border:OutlineInputBorder())),if(action=='mute'||action=='ban')...[const SizedBox(height:12),DropdownButtonFormField<String>(initialValue:duration,items:const ['1h','6h','12h','1d','3d','7d','30d','permanent'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setLocal(()=>duration=v??'1d'),decoration:const InputDecoration(labelText:'Duration'))]]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:Text(action.toUpperCase()))])));
    if(ok!=true)return;
    DateTime? until; if(action=='mute'||action=='ban'){final now=DateTime.now().toUtc();until=switch(duration){'1h'=>now.add(const Duration(hours:1)),'6h'=>now.add(const Duration(hours:6)),'12h'=>now.add(const Duration(hours:12)),'1d'=>now.add(const Duration(days:1)),'3d'=>now.add(const Duration(days:3)),'7d'=>now.add(const Duration(days:7)),'30d'=>now.add(const Duration(days:30)),_=>null};}
    try{await sb.rpc('owner_moderate_user',params:{'target_user':uid,'action_name':action,'reason_text':reason.text.trim(),'until_time':until?.toIso8601String(),'source_report':reportId});if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('${action.toUpperCase()} applied.')));await _load();}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Moderation failed: $e')));}
  }
  Widget _actions(String uid,{String? reportId})=>Wrap(spacing:7,runSpacing:7,children:[OutlinedButton(onPressed:()=>_moderate(uid,'warn',reportId:reportId),child:const Text('Warn')),OutlinedButton(onPressed:()=>_moderate(uid,'mute',reportId:reportId),child:const Text('Mute')),FilledButton(onPressed:()=>_moderate(uid,'ban',reportId:reportId),child:const Text('Ban')),TextButton(onPressed:()=>_moderate(uid,'unmute'),child:const Text('Unmute')),TextButton(onPressed:()=>_moderate(uid,'unban'),child:const Text('Unban'))]);
  @override Widget build(BuildContext context){final filtered=users.where((u){final q=userQuery.toLowerCase().trim();return q.isEmpty||('@${u['username']} ${(u['display_name']??'')} ${u['id']}').toLowerCase().contains(q);}).toList();return Scaffold(appBar:AppBar(title:const Text('Admin Panel')),body:loading?const Center(child:CircularProgressIndicator()):DefaultTabController(length:2,child:Column(children:[const TabBar(tabs:[Tab(text:'Reports'),Tab(text:'Users')]),Expanded(child:TabBarView(children:[ListView.builder(itemCount:reports.length,itemBuilder:(c,i){final r=reports[i];final evidence=(r['context'] as List?)??[];final target=r['reported_user_id']?.toString();return ExpansionTile(title:Text('${r['reason']} • ${r['status']}'),subtitle:Text((r['reported_body']??'').toString(),maxLines:2,overflow:TextOverflow.ellipsis),children:[Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('Context (up to 5 previous messages)',style:TextStyle(fontWeight:FontWeight.bold)),for(final x in evidence)Padding(padding:const EdgeInsets.symmetric(vertical:3),child:Text('• ${(x as Map)['body']}')),const Divider(),const Text('Reported message',style:TextStyle(fontWeight:FontWeight.bold)),Text((r['reported_body']??'').toString()),if((r['comment']??'').toString().isNotEmpty)...[const SizedBox(height:8),Text('Reporter comment: ${r['comment']}')],const SizedBox(height:10),if(target!=null)_actions(target,reportId:r['id']?.toString()),Wrap(spacing:8,children:[OutlinedButton(onPressed:()=>_status(r,'dismissed'),child:const Text('Dismiss')),TextButton(onPressed:()=>_status(r,'resolved'),child:const Text('Resolve without action'))])]))]);}),Column(children:[Padding(padding:const EdgeInsets.all(12),child:TextField(onChanged:(v)=>setState(()=>userQuery=v),decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'Search @username, name or UUID',border:OutlineInputBorder()))),Expanded(child:ListView.builder(itemCount:filtered.length,itemBuilder:(c,i){final u=filtered[i];return ExpansionTile(title:Row(children:[Flexible(child:Text('@${u['username']}')),if(u['verified']==true)const Padding(padding:EdgeInsets.only(left:5),child:Icon(Icons.verified,size:18,color:Colors.lightBlueAccent)),if(u['role']=='owner')const Padding(padding:EdgeInsets.only(left:7),child:Text('OWNER',style:TextStyle(fontSize:10,fontWeight:FontWeight.bold)))]),subtitle:Text((u['display_name']??'').toString()),children:[if(u['role']!='owner')Padding(padding:const EdgeInsets.fromLTRB(16,0,16,12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[_actions(u['id'].toString()),TextButton(onPressed:()=>_verify(u),child:Text(u['verified']==true?'Unverify':'Verify'))]))]);}))])]))])));}
}

