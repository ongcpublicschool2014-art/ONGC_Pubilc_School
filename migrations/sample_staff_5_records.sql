-- ============================================================================
-- SAMPLE DATA: 5 staff for DEMO SCHOOL (ins_id 1), year 2026-2027.
-- ============================================================================
-- 5 rows each in public.schstaff, public.staff_experience and
-- ongc20262027.staffmast (employee codes EMP001-EMP005). Made-up people,
-- @example.com e-mail addresses, no passwords. One transaction.
-- Run ONCE: a second run stops on the employee-code unique index.
-- To remove:  DELETE FROM public.schstaff WHERE emailid LIKE '%@example.com';
--             (staff_experience and staffmast rows go with them)
-- ============================================================================

BEGIN;

WITH src (emp_code, stafname, shortname, gender, dob, joindate, qualification, experience,
          address, city, mobileno, emailid, bloodgroup, religion, community_id, transportreq,
          designation, prev_school, exp_from, exp_to, exp_years) AS (
  VALUES
    ('EMP001', 'Lakshmi Narayanan R', 'LNR', 'F', DATE '1978-04-12', DATE '2015-06-01', 'M.Sc., M.Ed.', '22 years in teaching and administration',
     '14 Gandhi Street', 'Puducherry', '9840011001', 'lakshmi.r@example.com', 'O+', 'Hindu', 1, 'OWN',
     'Principal', 'St. Mary''s Matric Hr. Sec. School', DATE '2004-06-01', DATE '2015-05-31', '11 Years'),
    ('EMP002', 'Senthil Kumar P', 'SKP', 'M', DATE '1985-09-23', DATE '2018-06-04', 'M.Sc., B.Ed.', '12 years teaching Mathematics',
     '7 Nehru Nagar', 'Karaikal', '9840011002', 'senthil.p@example.com', 'B+', 'Hindu', 2, 'BUS',
     'Teacher', 'Vivekananda Vidyalaya', DATE '2012-06-04', DATE '2018-05-31', '6 Years'),
    ('EMP003', 'Fathima Begum S', 'FBS', 'F', DATE '1990-01-15', DATE '2020-06-08', 'M.A., B.Ed.', '8 years teaching English',
     '22 Mosque Road', 'Karaikal', '9840011003', 'fathima.s@example.com', 'A+', 'Muslim', 1, 'BUS',
     'Teacher', 'Crescent Higher Secondary School', DATE '2016-06-06', DATE '2020-05-29', '4 Years'),
    ('EMP004', 'John Peter A', 'JPA', 'M', DATE '1982-11-30', DATE '2016-06-06', 'M.P.Ed.', '15 years as Physical Director',
     '3 Church Street', 'Puducherry', '9840011004', 'john.a@example.com', 'AB+', 'Christian', 1, 'OWN',
     'Physical Director', 'Don Bosco Matriculation School', DATE '2008-06-02', DATE '2016-05-31', '8 Years'),
    ('EMP005', 'Meena Kumari T', 'MKT', 'F', DATE '1993-07-08', DATE '2022-06-06', 'B.Com., PGDCA', '5 years in school office accounts',
     '41 Bharathi Salai', 'Karaikal', '9840011005', 'meena.t@example.com', 'O-', 'Hindu', 2, 'BUS',
     'Office Assistant', 'Sri Sankara Vidyalaya', DATE '2019-06-03', DATE '2022-05-31', '3 Years')
),
ins AS (
  INSERT INTO public.schstaff (ins_id, stafname, shortname, gender, dob, joindate, qualification, experience,
                               address, city, mobileno, emailid, bloodgroup, religion, community_id, nationality,
                               transportreq, staftermin, created_by, updated_by)
  SELECT 1, stafname, shortname, gender, dob, joindate, qualification, experience,
         address, city, mobileno, emailid, bloodgroup, religion, community_id, 'Indian',
         transportreq, 0, 2, 2
    FROM src
  RETURNING staf_id, emailid
),
ex AS (
  INSERT INTO public.staff_experience (staf_id, ins_id, schoolname, experiencefrom, experienceto, experienceyears, created_by, updated_by)
  SELECT i.staf_id, 1, s.prev_school, s.exp_from, s.exp_to, s.exp_years, 2, 2
    FROM ins i JOIN src s ON s.emailid = i.emailid
  RETURNING staf_id
)
INSERT INTO ongc20262027.staffmast (staf_id, emp_code, stafname, shortname, mobile_no, emailid, designation, is_active, transportreq, created_by, updated_by)
SELECT i.staf_id, s.emp_code, s.stafname, s.shortname, s.mobileno, s.emailid, s.designation, true, s.transportreq, 2, 2
  FROM ins i JOIN src s ON s.emailid = i.emailid;

COMMIT;
