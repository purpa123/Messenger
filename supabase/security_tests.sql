begin;
do $$ declare ids uuid[]; oid uuid; begin
 select array_agg(id order by id) into ids from (select id from public.profiles where role='user' order by id limit 2) t;
 select id into oid from public.profiles where role='owner' limit 1;
 if array_length(ids,1)<>2 or oid is null then raise exception 'Tests require two existing ordinary accounts and one owner'; end if;
 perform set_config('messenger.test_user1',ids[1]::text,true);
 perform set_config('messenger.test_user2',ids[2]::text,true);
 perform set_config('messenger.test_owner',oid::text,true);
end $$;
-- Transaction-local fixtures use existing account IDs and are always rolled back.
select set_config('request.jwt.claim.sub',current_setting('messenger.test_user1'),true);
update public.profiles set suspended_until=null,muted_until=null where id=current_setting('messenger.test_user1')::uuid;
update public.profiles set who_can_message_me='everyone',username_discovery_visibility='nobody',
 profile_photo_visibility='nobody',bio_visibility='nobody',last_seen_visibility='nobody',
 read_receipts_enabled=false,avatar_url='https://example.invalid/rls-test.png',bio='rls-test',last_seen_at=now()
 where id=current_setting('messenger.test_user2')::uuid;
delete from public.user_blocks where (blocker_id=current_setting('messenger.test_user1')::uuid and blocked_id=current_setting('messenger.test_user2')::uuid)
 or (blocked_id=current_setting('messenger.test_user1')::uuid and blocker_id=current_setting('messenger.test_user2')::uuid);
do $$ declare cid uuid; mid uuid; begin
 select id into cid from public.conversations where dm_user_low=current_setting('messenger.test_user1')::uuid and dm_user_high=current_setting('messenger.test_user2')::uuid;
 if cid is null then insert into public.conversations(created_by,dm_user_low,dm_user_high) values(auth.uid(),auth.uid(),current_setting('messenger.test_user2')::uuid) returning id into cid; end if;
 insert into public.conversation_members(conversation_id,user_id) values(cid,auth.uid()),(cid,current_setting('messenger.test_user2')::uuid) on conflict do nothing;
 update public.conversation_members set last_read_at=now() where conversation_id=cid and user_id=current_setting('messenger.test_user2')::uuid;
 insert into public.messages(conversation_id,sender_id,body) values(cid,current_setting('messenger.test_user2')::uuid,'rls-test') returning id into mid;
 perform set_config('messenger.test_conv',cid::text,true);
 perform set_config('messenger.test_message',mid::text,true);
end $$;
set local role authenticated;
do $$ declare x record; denied boolean:=false; cid uuid:=current_setting('messenger.test_conv')::uuid; mid uuid:=current_setting('messenger.test_message')::uuid; rid uuid; begin
 if exists(select 1 from public.profiles where id=current_setting('messenger.test_user2')::uuid) then raise exception 'TEST: direct profile leak'; end if;
 select * into x from public.get_profile_privacy(current_setting('messenger.test_user2')::uuid);
 if x.avatar_url is not null or x.bio is not null or x.last_seen_at is not null or x.admin_override is true then raise exception 'TEST: masked RPC leak'; end if;
 if exists(select 1 from public.search_profiles_privacy('') where id=current_setting('messenger.test_user2')::uuid) then raise exception 'TEST: hidden discovery leak'; end if;
 if exists(select 1 from public.get_my_profile_private() where id<>auth.uid()) then raise exception 'TEST: own profile RPC leak'; end if;
 begin perform public.admin_list_profiles_private(); exception when raise_exception then if sqlerrm<>'Admin access required' then raise; end if; denied:=true; end;
 if not denied then raise exception 'TEST: admin API allowed non-owner'; end if;
 if has_column_privilege('authenticated','public.profiles','role','UPDATE') or has_column_privilege('authenticated','public.profiles','role','INSERT') then raise exception 'TEST: role escalation privilege'; end if;
 if has_column_privilege('authenticated','public.conversation_members','conversation_id','UPDATE') or has_column_privilege('authenticated','public.messages','conversation_id','UPDATE') then raise exception 'TEST: mutable chat identity'; end if;
 if has_column_privilege('authenticated','public.conversation_members','last_read_at','SELECT') then raise exception 'TEST: receipt direct read'; end if;
 if exists(select 1 from public.get_conversation_receipts(cid) where user_id=current_setting('messenger.test_user2')::uuid and last_read_at is not null) then raise exception 'TEST: receipt privacy leak'; end if;
 if (select count(*) from public.get_conversation_member_ids(cid))<>2 then raise exception 'TEST: E2EE membership lookup broken'; end if;
 if not messenger_private.can_contact(current_setting('messenger.test_user2')::uuid,false) or messenger_private.can_contact(current_setting('messenger.test_user2')::uuid,true) then raise exception 'TEST: discovery contact rule'; end if;
 insert into public.messages(conversation_id,sender_id,body) values(cid,auth.uid(),'rls-test allowed send');
 rid:=public.report_message(mid,'Other','rls-test');
 if rid is null then raise exception 'TEST: report creation failed'; end if;
 perform public.get_my_dm_inbox();
 -- Column permission must prevent writing role even on one's own row.
 begin update public.profiles set role='owner' where id=auth.uid(); raise exception 'TEST: role escalated'; exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Reverse-direction blocks and moderation must be seen by the policy helper.
insert into public.user_blocks(blocker_id,blocked_id) values(current_setting('messenger.test_user2')::uuid,current_setting('messenger.test_user1')::uuid);
set local role authenticated;
do $$ begin
 if messenger_private.can_contact(current_setting('messenger.test_user2')::uuid,false) then raise exception 'TEST: reverse block bypass'; end if;
 begin insert into public.messages(conversation_id,sender_id,body) values(current_setting('messenger.test_conv')::uuid,auth.uid(),'rls-test blocked send'); raise exception 'TEST: blocked send allowed'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claim.sub',current_setting('messenger.test_owner'),true);
set local role authenticated;
do $$ declare x record; begin
 select * into x from public.get_profile_privacy(current_setting('messenger.test_user2')::uuid);
 if x.avatar_url is null or x.bio is null or x.last_seen_at is null or x.admin_override is not true then raise exception 'TEST: owner override broken'; end if;
 perform public.admin_list_profiles_private();
 begin perform public.get_conversation_receipts(current_setting('messenger.test_conv')::uuid); raise exception 'TEST: nonmember receipt allowed'; exception when insufficient_privilege then null; end;
 begin perform public.get_conversation_member_ids(current_setting('messenger.test_conv')::uuid); raise exception 'TEST: nonmember IDs allowed'; exception when insufficient_privilege then null; end;
 if exists(select 1 from public.messages where conversation_id=current_setting('messenger.test_conv')::uuid) then raise exception 'TEST: nonmember message read'; end if;
end $$;
reset role;
set local role anon;
do $$ begin
 if has_function_privilege('anon','public.get_profile_privacy(uuid)','EXECUTE') then raise exception 'TEST: anonymous profile RPC'; end if;
 if has_table_privilege('anon','public.messages','TRUNCATE') or has_table_privilege('authenticated','public.messages','TRUNCATE') then raise exception 'TEST: dangerous truncate grant'; end if;
end $$;
rollback;
select 'PASS: profile masking, discovery, owner override, receipts, membership, send, block, report, escalation and nonmember isolation; all fixture changes rolled back' as test;
