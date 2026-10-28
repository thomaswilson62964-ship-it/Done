-- شغّل الملف ده كله مرة واحدة في Supabase: SQL Editor -> New query -> Run

create table if not exists public.docs(
  collection text not null,
  id text not null,
  data jsonb not null default '{}',
  updated_at timestamptz not null default now(),
  primary key(collection,id)
);
create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  is_admin boolean not null default false,
  approved boolean not null default false -- الحساب الجديد مبيشوفش حاجة لحد ما الأدمن يوافق
);
alter table public.profiles add column if not exists approved boolean not null default false;

create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path=public as
$$ select coalesce((select is_admin from public.profiles where id=auth.uid()),false) $$;

create or replace function public.is_approved() returns boolean
language sql security definer stable set search_path=public as
$$ select coalesce((select approved or is_admin from public.profiles where id=auth.uid()),false) $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path=public as
$$ begin insert into public.profiles(id) values(new.id) on conflict do nothing; return new; end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.merge_doc(c text,i text,patch jsonb) returns void
language plpgsql as
$$ begin
  update public.docs set data=data||patch, updated_at=now() where collection=c and id=i;
  if not found then raise exception 'not_found'; end if;
end $$;

alter table public.docs enable row level security;
alter table public.profiles enable row level security;

drop policy if exists p_profile on public.profiles;
create policy p_profile on public.profiles for select to authenticated using (id=auth.uid() or public.is_admin());
drop policy if exists p_profile_upd on public.profiles;
create policy p_profile_upd on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- القراءة: الأدمن يشوف كل حاجة ما عدا المشاريع الخاصة وتوكنات الواتساب وصور الوجوه. العضو يشوف ليدزه وكولاته وتحديثاته بس.
-- المشروع: صاحبه يشوفه، وأي حد يشوفه لو vis='all' (للقراءة فقط).
drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to authenticated
using (public.is_approved() and (
  (collection='projects' and (data->>'owner'=auth.uid()::text or data->>'vis'='all'))
  or (collection<>'projects' and ((public.is_admin() and collection not in ('wa_meta','avatars'))
    or collection not in ('leads','calls','voices','avatars','avatar_meta','hook_meta','updates','wa_meta')
    or (collection='leads' and data->>'owner'=auth.uid()::text)
    or (collection='calls' and data->>'by'=auth.uid()::text)
    or (collection='voices' and data->>'by'=auth.uid()::text)
    or (collection='avatars' and id=auth.uid()::text)
    or (collection='wa_meta' and id=auth.uid()::text)
    or (collection='updates' and (data->>'by' is null or data->>'by'=auth.uid()::text))))
));

-- الإضافة والتعديل: الأدمن أي حاجة (إلا مشاريع غيره). العضو يضيف ليده ومشاريعه وبياناته هو بس.
drop policy if exists docs_insert on public.docs;
create policy docs_insert on public.docs for insert to authenticated
with check ((collection='members' and id=auth.uid()::text) or (public.is_approved() and ((public.is_admin() and collection not in ('projects','wa_meta','avatars'))
  or (collection='leads' and data->>'owner'=auth.uid()::text)
  or (collection='calls' and data->>'by'=auth.uid()::text)
  or (collection='voices' and data->>'by'=auth.uid()::text)
  or (collection='avatars' and id=auth.uid()::text)
  or (collection='wa_meta' and id=auth.uid()::text)
  or (collection='projects' and data->>'owner'=auth.uid()::text)
  or (collection='members' and id=auth.uid()::text))));

drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update to authenticated
using ((collection='members' and id=auth.uid()::text) or (public.is_approved() and ((public.is_admin() and collection not in ('projects','wa_meta','avatars'))
  or (collection='leads' and data->>'owner'=auth.uid()::text)
  or (collection='calls' and data->>'by'=auth.uid()::text)
  or (collection='voices' and data->>'by'=auth.uid()::text)
  or (collection='avatars' and id=auth.uid()::text)
  or (collection='wa_meta' and id=auth.uid()::text)
  or (collection='projects' and data->>'owner'=auth.uid()::text)
  or (collection='members' and id=auth.uid()::text))))
with check ((collection='members' and id=auth.uid()::text) or (public.is_approved() and ((public.is_admin() and collection not in ('projects','wa_meta','avatars'))
  or (collection='leads' and data->>'owner'=auth.uid()::text)
  or (collection='calls' and data->>'by'=auth.uid()::text)
  or (collection='voices' and data->>'by'=auth.uid()::text)
  or (collection='avatars' and id=auth.uid()::text)
  or (collection='wa_meta' and id=auth.uid()::text)
  or (collection='projects' and data->>'owner'=auth.uid()::text)
  or (collection='members' and id=auth.uid()::text))));

-- الحذف: الأدمن (ما عدا المشاريع) أو صاحب المشروع
drop policy if exists docs_delete on public.docs;
create policy docs_delete on public.docs for delete to authenticated
using (public.is_approved() and ((public.is_admin() and collection not in ('projects','wa_meta','avatars')) or (collection='projects' and data->>'owner'=auth.uid()::text)
  or (collection='voices' and data->>'by'=auth.uid()::text)));

-- مخزن صور الشخصيات المولّدة (الكتابة فيه من الـ Edge Function بس)
insert into storage.buckets (id,name,public) values ('avatars','avatars',true) on conflict (id) do nothing;

-- مخزن الفويس فيدباك: خاص. كل موظف يرفع ويسمع ويمسح فويساته في فولدره بس، والأدمن يسمع الكل.
insert into storage.buckets (id,name,public) values ('voice','voice',false) on conflict (id) do nothing;
drop policy if exists voice_up on storage.objects;
create policy voice_up on storage.objects for insert to authenticated
with check (public.is_approved() and bucket_id='voice' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists voice_rd on storage.objects;
create policy voice_rd on storage.objects for select to authenticated
using (public.is_approved() and bucket_id='voice' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));
drop policy if exists voice_del on storage.objects;
create policy voice_del on storage.objects for delete to authenticated
using (public.is_approved() and bucket_id='voice' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));

-- تحديث لحظي
alter publication supabase_realtime add table public.docs;

-- بعد ما تسجّل حسابك في الموقع، خلّي نفسك أدمن (غيّر الإيميل):
-- update public.profiles set is_admin=true where id=(select id from auth.users where email='YOUR_EMAIL');
