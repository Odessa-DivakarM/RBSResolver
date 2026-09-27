/*
  RBS Resolver — export users, their login roles and the site-level default as one JSON document.

  READ-ONLY: a single SELECT. Nothing is written to the database.
  Needs SQL Server 2016 or later (FOR JSON, JSON_QUERY). Nothing from 2017+ is used.

  Run it with scripts/export-users.ps1, which writes the result to a file. In SSMS the grid cuts long text
  at 65,535 characters, so SSMS is only good for a single user (set @LoginName below).

  What it mirrors in Odessa.Framework (Lw.Domain.Base.Extension):
    - A user's roles: Components/RolesForUser/GetRolesForUser.cs — the roles login loads:
        RolesForUsers ⋈ Roles ⋈ RoleFunctions, all three IsActive. No date checks, no approval check.
    - Every user is exported, including ones who can't log in. Among other checks (site access, user type,
      domain, password, licence — not exported), login (Services/Security/SecurityService.cs LoginUser,
      Lw.Domain.Base/Behaviors/UserLoginAuditBehavior.xaml) refuses a user who:
        - isn't exactly 'Approved';
        - has no active role (UserContextHelper throws InvalidRolesForUser), or a role default or site default
          Permission.Parse can't read — a blank role default is stored back as '_' (AbstractEnum.Value), which
          can't be read either;
        - is blocked: LoginBlockedTime set, IsLoginBlocked, and IsAdminBlocked or a lockout of 0 minutes or
          still inside LoginBlockedTime + AccountLockoutDurationInMins (SecurityConfigs, first row);
        - is before LoginEffectiveDate (a NULL one never passes) or after LoginExpiryDate (NULL = no expiry),
          both against the web server's local date.
      Those fields are exported as they are for the importer to show.
    - The site-level default: Helpers/UserContextHelper.cs FetchUserRoles reads the global parameter
      UserRole.DefaultRolePermission (Caching/Providers/GlobalParamConfigProvider.cs: IsActive = 1, key
      Category + "." + Name matched exactly, case and trailing spaces included) and falls back to "Full" when
      there is no such row. siteLevelDefault is that row's Value exactly as stored, or null when there is no
      row. The importer turns it into a code the way Permission.Parse does ('f' and 'Full' are Full, blank is
      Undefined, anything else unparseable makes every login fail). A portfolio can override it, but a fresh
      login reads it before the portfolio is known, so the override is not exported.
    - A role's default is exported as stored. 'X' (upper case only: PermissionValues.IsX) means "use the
      site-level default"; a lower-case 'x' is Undefined; the importer parses the rest like Permission.Parse.
*/
SET NOCOUNT ON;
SET LOCK_TIMEOUT 30000;   -- fail after 30 s rather than wait behind a long write

-- <parameters> (export-users.ps1 removes this block and passes @LoginName itself)
DECLARE @LoginName nvarchar(100) = NULL;   -- NULL = every user; or one login name, e.g. N'jdoe'
-- </parameters>

SELECT (
  SELECT
    'rbs-users/1'                                    AS [format],
    CONVERT(varchar(33), SYSDATETIMEOFFSET(), 127)   AS [exportedAt],
    CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS [source.server],
    DB_NAME()                                        AS [source.database],
    (SELECT gp.Value
       FROM dbo.GlobalParameters gp
      WHERE gp.Category COLLATE Latin1_General_BIN2 = N'UserRole'
        AND gp.Name     COLLATE Latin1_General_BIN2 = N'DefaultRolePermission'
        AND DATALENGTH(gp.Category) = DATALENGTH(N'UserRole')            -- = ignores trailing spaces;
        AND DATALENGTH(gp.Name)     = DATALENGTH(N'DefaultRolePermission') -- the framework's key doesn't
        AND gp.IsActive = 1)                         AS [siteLevelDefault],
    -- The framework reads SecurityConfigs.First() (no order); there is normally a single row.
    (SELECT TOP (1) sc.AccountLockoutDurationInMins FROM dbo.SecurityConfigs sc ORDER BY sc.Id)
                                                     AS [accountLockoutDurationInMins],
    JSON_QUERY(ISNULL((
      SELECT r.Name AS [name], r.DefaultPermission AS [defaultPermission]
        FROM dbo.Roles r
        JOIN dbo.RoleFunctions rf ON rf.Id = r.RoleFunctionId
       WHERE r.IsActive = 1 AND rf.IsActive = 1
       ORDER BY r.Name
         FOR JSON PATH), N'[]'))                     AS [roles],
    JSON_QUERY(ISNULL((
      SELECT u.Id             AS [id],
             u.LoginName      AS [loginName],
             u.FullName       AS [fullName],
             u.ApprovalStatus AS [approvalStatus],
             u.IsLoginBlocked AS [isLoginBlocked],
             u.IsAdminBlocked AS [isAdminBlocked],
             -- milliseconds: JavaScript's date format only promises three fraction digits
             CONVERT(varchar(33), CAST(u.LoginBlockedTime AS datetimeoffset(3)), 127) AS [loginBlockedTime],
             CONVERT(char(10), u.LoginEffectiveDate, 23) AS [loginEffectiveDate],
             CONVERT(char(10), u.LoginExpiryDate, 23)    AS [loginExpiryDate],
             JSON_QUERY(ISNULL((
               SELECT r.Name AS [name]
                 FROM dbo.RolesForUsers rfu
                 JOIN dbo.Roles r          ON r.Id  = rfu.RoleId
                 JOIN dbo.RoleFunctions rf ON rf.Id = r.RoleFunctionId
                WHERE rfu.UserId = u.Id AND rfu.IsActive = 1 AND r.IsActive = 1 AND rf.IsActive = 1
                ORDER BY r.Name
                  FOR JSON PATH), N'[]'))            AS [roles]
        FROM dbo.Users u
       WHERE @LoginName IS NULL OR u.LoginName = @LoginName
       ORDER BY u.LoginName, u.Id
         FOR JSON PATH, INCLUDE_NULL_VALUES), N'[]')) AS [users]
  FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES
) AS rbsUsersJson;
