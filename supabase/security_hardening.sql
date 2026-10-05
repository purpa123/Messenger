-- Exact applied Messenger 0.8.7 audit fixes. Re-runnable on the existing Messenger schema.
grant update(username_discovery_visibility,profile_photo_visibility,bio_visibility) on public.profiles to authenticated;
grant update(read_at) on public.notifications to authenticated;
create schema if not exists messenger_private;
revoke all on schema messenger_private from public,anon;
grant usage on schema messenger_private to authenticated;
create or replace function messenger_private.can_contact(target_id uuid, require_discovery boolean default false)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and target_id<>auth.uid()
   and exists(select 1 from public.profiles a where a.id=auth.uid()
     and (a.suspended_until is null or a.suspended_until<=now())
     and (a.muted_until is null or a.muted_until<=now()))
   and exists(select 1 from public.profiles p where p.id=target_id
     and p.who_can_message_me='everyone'
     and (not require_discovery or p.username_discovery_visibility='everyone'
       or exists(select 1 from public.profiles a where a.id=auth.uid() and a.role='owner')))
   and not exists(select 1 from public.user_blocks b
     where (b.blocker_id=auth.uid() and b.blocked_id=target_id)
        or (b.blocked_id=auth.uid() and b.blocker_id=target_id));
$$;
revoke all on function messenger_private.can_contact(uuid,boolean) from public,anon;
grant execute on function messenger_private.can_contact(uuid,boolean) to authenticated;

alter policy conversations_create_dm on public.conversations with check (
 created_by=(select auth.uid()) and kind='dm' and dm_user_low<dm_user_high
 and ((select auth.uid())=dm_user_low or (select auth.uid())=dm_user_high)
 and messenger_private.can_contact(case when auth.uid()=dm_user_low then dm_user_high else dm_user_low end,true));
alter policy messages_send_member on public.messages with check (
 sender_id=(select auth.uid()) and exists(select 1 from public.conversation_members cm
 where cm.conversation_id=messages.conversation_id and cm.user_id=(select auth.uid()))
 and exists(select 1 from public.conversations c where c.id=messages.conversation_id
 and (c.dm_user_low=auth.uid() or c.dm_user_high=auth.uid())
 and messenger_private.can_contact(case when c.dm_user_low=auth.uid() then c.dm_user_high else c.dm_user_low end,false)));

-- Only own preference rows are directly readable. Receipt RPC masks other users.
revoke select on public.conversation_members from authenticated;
grant select(conversation_id,user_id,joined_at,delivered_at,muted,archived,favorite,cleared_before,marked_unread_at) on public.conversation_members to authenticated;
create or replace function public.get_conversation_receipts(target_conversation uuid)
returns table(user_id uuid,delivered_at timestamptz,last_read_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.conversation_members cm
   where cm.conversation_id=target_conversation and cm.user_id=auth.uid()) then
   raise exception 'Not a conversation member' using errcode='42501';
 end if;
 return query select cm.user_id,cm.delivered_at,
   case when p.read_receipts_enabled or cm.user_id=auth.uid() then cm.last_read_at else null end
 from public.conversation_members cm join public.profiles p on p.id=cm.user_id
 where cm.conversation_id=target_conversation;
end $$;
alter function public.get_my_dm_inbox() security definer;
create or replace function public.get_conversation_member_ids(target_conversation uuid)
returns table(user_id uuid) language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.conversation_members cm
   where cm.conversation_id=target_conversation and cm.user_id=auth.uid()) then
   raise exception 'Not a conversation member' using errcode='42501';
 end if;
 return query select cm.user_id from public.conversation_members cm where cm.conversation_id=target_conversation;
end $$;
-- Key delivery is available through the validated store_e2ee_conversation_key RPC.



grant execute on function public.get_conversation_receipts(uuid), public.get_conversation_member_ids(uuid) to authenticated;
revoke execute on function public.get_conversation_receipts(uuid), public.get_conversation_member_ids(uuid) from public,anon;
alter policy profiles_read on public.profiles using(id=(select auth.uid()));
revoke execute on function public.get_profile_privacy(uuid),public.search_profiles_privacy(text),public.get_my_profile_private(),public.admin_list_profiles_private(),public.create_report_result_notification() from public,anon;
grant execute on function public.get_profile_privacy(uuid),public.search_profiles_privacy(text),public.get_my_profile_private(),public.admin_list_profiles_private() to authenticated;
revoke execute on function public.create_report_result_notification() from authenticated;
alter function public.get_profile_privacy(uuid) set search_path='';
alter function public.search_profiles_privacy(text) set search_path='';
alter function public.get_my_profile_private() set search_path='';
alter function public.admin_list_profiles_private() set search_path='';
alter function public.create_report_result_notification() set search_path='';
notify pgrst,'reload schema';
-- Prevent moving a membership/message to a different conversation via UPDATE.
revoke update,insert on public.conversation_members from authenticated;
grant insert(conversation_id,user_id) on public.conversation_members to authenticated;
grant update(last_read_at,delivered_at,muted,archived,favorite,cleared_before,marked_unread_at) on public.conversation_members to authenticated;
revoke update on public.messages from authenticated;
grant update(body,reply_to,edited_at,deleted_at,message_type,attachment_path,attachment_mime,attachment_size,
 encryption_version,ciphertext,encryption_nonce,sender_device_id,key_version,attachment_encryption_version,attachment_nonce,attachment_mac)
 on public.messages to authenticated;
alter policy messages_edit_own on public.messages using (
 sender_id=(select auth.uid()) and exists(select 1 from public.conversation_members cm
 where cm.conversation_id=messages.conversation_id and cm.user_id=(select auth.uid())))
 with check(sender_id=(select auth.uid()) and exists(select 1 from public.conversation_members cm
 where cm.conversation_id=messages.conversation_id and cm.user_id=(select auth.uid())));
revoke update on public.typing_states from authenticated;
grant update(is_typing,updated_at) on public.typing_states to authenticated;

-- Restrict report creation and prevent forging resolved reports or identities.
revoke insert,update on public.message_reports from authenticated;
grant insert(reporter_id,reported_message_id,reported_user_id,conversation_id,reason,comment,reported_body,reported_created_at,context)
 on public.message_reports to authenticated;
grant update(status) on public.message_reports to authenticated;
alter policy reports_insert_self on public.message_reports with check (
 reporter_id=(select auth.uid()) and status='open' and reporter_notified_at is null
 and exists(select 1 from public.messages m where m.id=message_reports.reported_message_id
 and m.conversation_id=message_reports.conversation_id and m.sender_id=message_reports.reported_user_id
 and m.sender_id<>auth.uid()) and exists(select 1 from public.conversation_members cm
 where cm.conversation_id=message_reports.conversation_id and cm.user_id=(select auth.uid())));
drop policy if exists reports_read_self on public.message_reports;
create policy reports_read_self on public.message_reports for select to authenticated using(reporter_id=(select auth.uid()));
grant update(read_at) on public.notifications to authenticated;


-- No client feature requires TRUNCATE; this privilege is not governed by RLS.
revoke truncate on public.app_releases,public.conversation_members,public.conversation_pins,public.conversations,public.e2ee_conversation_keys,public.e2ee_devices,public.legal_acceptances,public.message_drafts,public.message_reactions,public.message_reports,public.messages,public.moderation_actions,public.notifications,public.profiles,public.push_tokens,public.typing_states,public.user_blocks from anon,authenticated;

revoke select,update on public.e2ee_devices from authenticated;
grant select(id,user_id,device_id,identity_public_key,encryption_public_key,revoked_at) on public.e2ee_devices to authenticated;
grant update(last_seen_at,revoked_at,identity_public_key,encryption_public_key) on public.e2ee_devices to authenticated;
