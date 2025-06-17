# Problem Statement: Windmill vs. Cloudron PostgreSQL Role Management

## Summary

There is a fundamental mismatch between Windmill's database requirements and the constraints imposed by Cloudron's PostgreSQL addon. This document outlines the technical details of Windmill's expectations, Cloudron's limitations, and why the current Dockerfile and database approach will not work without modification.

---

## What Windmill Expects

- **Role-Based Access Control (RBAC):**  
  Windmill requires the creation of two PostgreSQL roles: `windmill_admin` and `windmill_user`. These roles are used for:
  - Database migrations
  - Runtime access control (RBAC)
  - Assigning privileges and, for `windmill_admin`, the `BYPASSRLS` (Bypass Row-Level Security) attribute

- **Database Initialization:**  
  Windmill's official setup scripts (e.g., `init-db-as-superuser.sql`) assume the ability to:
  - Create new roles (`CREATE ROLE`)
  - Grant privileges and role memberships
  - Assign `BYPASSRLS` to `windmill_admin`
  - Grant these roles to the application's login user

- **Migration Behavior:**  
  During startup or migration, Windmill attempts to create these roles and assign the necessary privileges. Some versions attempt to work around missing `BYPASSRLS` by creating permissive RLS policies, but role creation is still assumed.

---

## Cloudron PostgreSQL Addon Limitations

- **No Superuser or CREATEROLE Privileges:**  
  Cloudron provisions a dedicated PostgreSQL user for each app (via environment variables like `CLOUDRON_POSTGRESQL_USERNAME`). This user:
  - Owns its own database and schema
  - **Cannot create new roles** (`CREATEROLE` is not granted)
  - **Cannot assign `BYPASSRLS`** or other superuser-level attributes

- **Isolated Database Environment:**  
  The app user can create tables, sequences, and manage data within its own database, but cannot affect global PostgreSQL roles or privileges.

- **Immutable Addon Behavior:**  
  The Cloudron platform does not provide hooks or options to pre-create roles or grant additional privileges to the app user.

---

## Why the Current Approach Fails

- **Role Creation Fails:**  
  When Windmill's migrations or initialization scripts attempt to run `CREATE ROLE windmill_user;` or `CREATE ROLE windmill_admin;`, these commands fail due to lack of `CREATEROLE` privilege.

- **Privilege Assignment Fails:**  
  Attempts to grant privileges or assign roles to the app user also fail for the same reason.

- **BYPASSRLS Unavailable:**  
  Even if roles could be created, the app user cannot assign `BYPASSRLS` to any role, which is required for Windmill's admin logic.

- **Result:**  
  Windmill's startup or migration process will error out, leaving the application in a broken state. Even if some tables are created, RBAC and RLS policies will not function as intended, and administrative features may be inaccessible.

---

## Additional Context

- **Workarounds in Other Environments:**  
  In managed PostgreSQL environments (e.g., Azure), users have worked around the lack of `BYPASSRLS` by creating permissive RLS policies for the admin role. However, this still requires the ability to create roles, which Cloudron does not permit.

- **Recent Windmill Changes:**  
  Some recent versions of Windmill attempt to automatically create these permissive policies if `BYPASSRLS` is unavailable. However, the fundamental requirement to create roles remains, and cannot be satisfied on Cloudron.

---

## Conclusion

**Without patching Windmill to avoid role creation and to treat the Cloudron-provided database user as the effective admin/user, Windmill cannot be deployed on Cloudron using the standard Dockerfile and database approach.**  
A custom patch or fork is required to bypass role creation and adapt RBAC logic to Cloudron's constraints.
