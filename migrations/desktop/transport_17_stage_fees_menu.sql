-- Shows the new Stage Fees menu to Admins of schools whose Admin role
-- already has a saved menu list in Roles & Access, the same way
-- transport_14_vehicle_allotment_menu.sql does for Vehicle Allotment.
-- That saved list overrides the app's default menus, so a new menu stays
-- hidden until it is added to it.
-- A role with no saved list is not touched: it already gets the default menus.
-- Other roles are not touched either: the Admin grants those in Roles & Access.
-- Runs once (a later update must not give the menu back to a role it was
-- taken from). Safe to run again by hand: an existing row is left as it is.
BEGIN;

INSERT INTO public.rolemenuaccess (ins_id, ur_id, menulabel, createdby)
SELECT r.ins_id, r.ur_id, 'Stage Fees', 'TRANSPORT SETUP'
  FROM (SELECT DISTINCT a.ins_id, a.ur_id
          FROM public.rolemenuaccess a
         WHERE a.activestatus = 1
           AND EXISTS (SELECT 1 FROM public.institutionusers u
                        WHERE u.ins_id = a.ins_id AND u.ur_id = a.ur_id AND u.urname = 'Admin')) r
ON CONFLICT (ins_id, ur_id, menulabel) DO NOTHING;

COMMIT;
