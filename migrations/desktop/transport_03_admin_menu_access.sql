-- Shows the Transport menus to Admins of schools whose Admin role already has a
-- saved menu list in Roles & Access. That saved list overrides the app's default
-- menus, so new menus stay hidden until they are added to it.
-- A role with no saved list is not touched: it already gets the default menus.
-- Other roles are not touched either: the Admin grants those in Roles & Access.
-- Safe to run again.
INSERT INTO public.rolemenuaccess (ins_id, ur_id, menulabel, createdby)
SELECT r.ins_id, r.ur_id, m.label, 'TRANSPORT SETUP'
  FROM (SELECT DISTINCT a.ins_id, a.ur_id
          FROM public.rolemenuaccess a
         WHERE a.activestatus = 1
           AND EXISTS (SELECT 1 FROM public.institutionusers u
                        WHERE u.ins_id = a.ins_id AND u.ur_id = a.ur_id AND u.urname = 'Admin')) r
 CROSS JOIN (VALUES ('Transport Setup'), ('Routes & Stops'), ('Vehicles'), ('Transport Staff')) m(label)
ON CONFLICT (ins_id, ur_id, menulabel) DO NOTHING;
