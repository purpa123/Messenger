import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const supabaseUrl = 'https://vepgxpgasbkrloaaxgvh.supabase.co';
const supabasePublishableKey = 'sb_publishable_dIP2ZG4M85bRh771f4mh9A_DuSyGub4';
final sb = Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabasePublishableKey);
  runApp(const MessengerApp());
}

class MessengerApp extends StatelessWidget {
  const MessengerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Messenger',
    theme: ThemeData(colorSchemeSeed: Colors.deepPurple, brightness: Brightness.dark, useMaterial3: true),
    home: const AuthGate(),
  );
}

class AuthGate extends StatefulWidget { const AuthGate({super.key}); @override State<AuthGate> createState()=>_AuthGateState(); }
class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? sub;
  @override void initState(){super.initState();sub=sb.auth.onAuthStateChange.listen((_){if(mounted)setState((){});});}
  @override void dispose(){sub?.cancel();super.dispose();}
  @override Widget build(BuildContext context)=>sb.auth.currentSession==null?const AuthPage():const ProfileGate();
}

class AuthPage extends StatefulWidget { const AuthPage({super.key}); @override State<AuthPage> createState()=>_AuthPageState(); }
class _AuthPageState extends State<AuthPage> {
  final email=TextEditingController(), pass=TextEditingController(); bool login=true,busy=false;
  Future<void> go() async { setState(()=>busy=true); try { if(login){await sb.auth.signInWithPassword(email:email.text.trim(),password:pass.text);} else {await sb.auth.signUp(email:email.text.trim(),password:pass.text);} } on AuthException catch(e){msg(e.message);} finally{if(mounted)setState(()=>busy=false);} }
  void msg(String s){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));}
  @override Widget build(BuildContext c)=>Scaffold(body:SafeArea(child:Center(child:SingleChildScrollView(padding:const EdgeInsets.all(24),child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:440),child:Column(children:[const Icon(Icons.forum_rounded,size:72),const SizedBox(height:16),Text(login?'Welcome back':'Create account',style:Theme.of(c).textTheme.headlineMedium),const SizedBox(height:24),TextField(controller:email,keyboardType:TextInputType.emailAddress,decoration:const InputDecoration(labelText:'Email',border:OutlineInputBorder())),const SizedBox(height:12),TextField(controller:pass,obscureText:true,decoration:const InputDecoration(labelText:'Password',border:OutlineInputBorder())),const SizedBox(height:18),SizedBox(width:double.infinity,child:FilledButton(onPressed:busy?null:go,child:Text(busy?'Please wait...':login?'Sign in':'Sign up'))),TextButton(onPressed:()=>setState(()=>login=!login),child:Text(login?'Create an account':'I already have an account'))]))))));
}

class ProfileGate extends StatefulWidget { const ProfileGate({super.key}); @override State<ProfileGate> createState()=>_ProfileGateState(); }
class _ProfileGateState extends State<ProfileGate>{
  bool loading=true,exists=false; final username=TextEditingController(),display=TextEditingController();
  @override void initState(){super.initState();check();}
  Future<void> check()async{final id=sb.auth.currentUser!.id;final r=await sb.from('profiles').select('id').eq('id',id).maybeSingle();if(mounted)setState((){exists=r!=null;loading=false;});}
  Future<void> save()async{try{await sb.from('profiles').insert({'id':sb.auth.currentUser!.id,'username':username.text.trim(),'display_name':display.text.trim()});await check();}on PostgrestException catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.message)));}}
  @override Widget build(BuildContext c){if(loading)return const Scaffold(body:Center(child:CircularProgressIndicator()));if(exists)return const HomePage();return Scaffold(appBar:AppBar(title:const Text('Set up profile')),body:Padding(padding:const EdgeInsets.all(20),child:Column(children:[TextField(controller:username,decoration:const InputDecoration(labelText:'Username (3–24)',border:OutlineInputBorder())),const SizedBox(height:12),TextField(controller:display,decoration:const InputDecoration(labelText:'Display name',border:OutlineInputBorder())),const SizedBox(height:16),SizedBox(width:double.infinity,child:FilledButton(onPressed:save,child:const Text('Continue')))])));}
}

class HomePage extends StatefulWidget { const HomePage({super.key}); @override State<HomePage> createState()=>_HomePageState(); }
class _HomePageState extends State<HomePage>{
  List<Map<String,dynamic>> chats=[]; bool loading=true;
  @override void initState(){super.initState();load();}
  Future<void> load()async{final me=sb.auth.currentUser!.id;final rows=await sb.from('conversations').select('id,dm_user_low,dm_user_high,created_at').or('dm_user_low.eq.$me,dm_user_high.eq.$me').order('created_at',ascending:false);final out=<Map<String,dynamic>>[];for(final raw in rows){final r=Map<String,dynamic>.from(raw);final other=r['dm_user_low']==me?r['dm_user_high']:r['dm_user_low'];final p=await sb.from('profiles').select('username,display_name').eq('id',other).maybeSingle();r['other_id']=other;r['profile']=p;out.add(r);}if(mounted)setState((){chats=out;loading=false;});}
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:const Text('Messenger'),actions:[IconButton(onPressed:()=>sb.auth.signOut(),icon:const Icon(Icons.logout))]),floatingActionButton:FloatingActionButton(onPressed:()async{await Navigator.push(c,MaterialPageRoute(builder:(_)=>const SearchPage()));load();},child:const Icon(Icons.chat_bubble_outline)),body:RefreshIndicator(onRefresh:load,child:loading?const Center(child:CircularProgressIndicator()):chats.isEmpty?ListView(children:const [SizedBox(height:180),Center(child:Text('No chats yet. Tap + to find someone.'))]):ListView.builder(itemCount:chats.length,itemBuilder:(c,i){final x=chats[i],p=x['profile'] as Map<String,dynamic>?;final name=((p?['display_name']??'') as String).trim();final user=p?['username']??'Unknown';return ListTile(leading:CircleAvatar(child:Text(user.toString().substring(0,1).toUpperCase())),title:Text(name.isEmpty?'@$user':name),subtitle:Text('@$user'),onTap:()=>Navigator.push(c,MaterialPageRoute(builder:(_)=>ChatPage(conversationId:x['id'],title:name.isEmpty?'@$user':name)));})));}
}

class SearchPage extends StatefulWidget {const SearchPage({super.key});@override State<SearchPage> createState()=>_SearchPageState();}
class _SearchPageState extends State<SearchPage>{final q=TextEditingController();List<Map<String,dynamic>> results=[];
  Future<void> search(String s)async{if(s.trim().isEmpty){setState(()=>results=[]);return;}final me=sb.auth.currentUser!.id;final r=await sb.from('profiles').select('id,username,display_name').ilike('username','%${s.trim()}%').neq('id',me).limit(30);if(mounted)setState(()=>results=List<Map<String,dynamic>>.from(r));}
  Future<void> open(Map<String,dynamic> p)async{final me=sb.auth.currentUser!.id,other=p['id'] as String;final low=me.compareTo(other)<0?me:other,high=me.compareTo(other)<0?other:me;var conv=await sb.from('conversations').select('id').eq('dm_user_low',low).eq('dm_user_high',high).maybeSingle();String id;if(conv!=null){id=conv['id'];}else{final made=await sb.from('conversations').insert({'created_by':me,'kind':'dm','dm_user_low':low,'dm_user_high':high}).select('id').single();id=made['id'];await sb.from('conversation_members').insert([{'conversation_id':id,'user_id':me},{'conversation_id':id,'user_id':other}]);}if(!mounted)return;final dn=(p['display_name']??'').toString().trim();await Navigator.pushReplacement(context,MaterialPageRoute(builder:(_)=>ChatPage(conversationId:id,title:dn.isEmpty?'@${p['username']}':dn)));}
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:TextField(controller:q,autofocus:true,onChanged:search,decoration:const InputDecoration(hintText:'Search username...',border:InputBorder.none))),body:ListView.builder(itemCount:results.length,itemBuilder:(c,i){final p=results[i];return ListTile(title:Text((p['display_name']??'').toString().trim().isEmpty?'@${p['username']}':p['display_name']),subtitle:Text('@${p['username']}'),onTap:()=>open(p));}));}
}

class ChatPage extends StatefulWidget {final String conversationId,title;const ChatPage({super.key,required this.conversationId,required this.title});@override State<ChatPage> createState()=>_ChatPageState();}
class _ChatPageState extends State<ChatPage>{final input=TextEditingController();late final Stream<List<Map<String,dynamic>>> stream;
  @override void initState(){super.initState();stream=sb.from('messages').stream(primaryKey:['id']).eq('conversation_id',widget.conversationId).order('created_at');}
  Future<void> send()async{final t=input.text.trim();if(t.isEmpty)return;input.clear();try{await sb.from('messages').insert({'conversation_id':widget.conversationId,'sender_id':sb.auth.currentUser!.id,'body':t});}on PostgrestException catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.message)));}}
  @override Widget build(BuildContext c)=>Scaffold(appBar:AppBar(title:Text(widget.title)),body:Column(children:[Expanded(child:StreamBuilder<List<Map<String,dynamic>>>(stream:stream,builder:(c,s){if(!s.hasData)return const Center(child:CircularProgressIndicator());final data=s.data!;return ListView.builder(reverse:true,padding:const EdgeInsets.all(12),itemCount:data.length,itemBuilder:(c,i){final m=data[data.length-1-i],mine=m['sender_id']==sb.auth.currentUser!.id;return Align(alignment:mine?Alignment.centerRight:Alignment.centerLeft,child:Container(margin:const EdgeInsets.symmetric(vertical:3),padding:const EdgeInsets.symmetric(horizontal:14,vertical:10),constraints:BoxConstraints(maxWidth:MediaQuery.sizeOf(c).width*.78),decoration:BoxDecoration(color:mine?Theme.of(c).colorScheme.primaryContainer:Theme.of(c).colorScheme.surfaceContainerHighest,borderRadius:BorderRadius.circular(18)),child:Text(m['body'])));});})),SafeArea(top:false,child:Padding(padding:const EdgeInsets.fromLTRB(10,6,10,10),child:Row(children:[Expanded(child:TextField(controller:input,maxLines:4,minLines:1,onSubmitted:(_)=>send(),decoration:const InputDecoration(hintText:'Message...',border:OutlineInputBorder()))),const SizedBox(width:8),IconButton.filled(onPressed:send,icon:const Icon(Icons.send))])))]));}
}
