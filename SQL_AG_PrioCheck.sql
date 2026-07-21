-- CheckAGs_sqlcmd.sql (halt-on-first-error, errors-only, certificate-only)
-- Checks:
--   * Availability Group count within expected range (per instance)
--   * HADR enabled when AGs exist
--   * TDE certificate presence by name in master
--   * Encrypted DBs have a matching certificate (thumbprint match)
--   * Encrypted DBs use the expected certificate name
-- Output: Silent on success; prints ONE error line and HALTS on the first failure.

-- Make sqlcmd/SSMS stop on the first T-SQL error we THROW
:ON ERROR EXIT

-- ===== Global settings =====
:setvar CertName "20241003_nonprod"

-- ===== Instances + Expected AG ranges =====
:setvar Inst1 "VMSQLAGTEST01\ACURITY2019"
:setvar Inst1ExpectedAGMin 0
:setvar Inst1ExpectedAGMax 0

:setvar Inst2 "VMSQLAGTEST01\REPL2019"
:setvar Inst2ExpectedAGMin 0
:setvar Inst2ExpectedAGMax 0

:setvar Inst3 "VMSQLAGTEST02\ACURITY2019"
:setvar Inst3ExpectedAGMin 1
:setvar Inst3ExpectedAGMax 2147483647

:setvar Inst4 "VMSQLAGTEST02\REPL2019"
:setvar Inst4ExpectedAGMin 1
:setvar Inst4ExpectedAGMax 2147483647

-- ===== Reusable check block (no double quotes inside this string) =====
:setvar CheckBlock "
SET NOCOUNT ON;

DECLARE @machine sysname = CONVERT(sysname, SERVERPROPERTY('MachineName'));
DECLARE @instName sysname = CONVERT(sysname, SERVERPROPERTY('InstanceName'));
DECLARE @inst NVARCHAR(256) = CASE WHEN @instName IS NULL OR @instName = '' THEN @machine ELSE CONCAT(@machine, '\', @instName) END;

DECLARE @isHadr INT = CONVERT(INT, SERVERPROPERTY('IsHadrEnabled'));
DECLARE @agCount INT = (SELECT COUNT(*) FROM sys.availability_groups);

-- Use the @CertName bound outside this block
DECLARE @certExists INT = (SELECT COUNT(*) FROM master.sys.certificates WHERE name = @CertName);

-- Count encrypted DBs (encrypted or in progress)
DECLARE @encryptedDbCount INT = (
    SELECT COUNT(*)
    FROM sys.databases AS db
    JOIN sys.dm_database_encryption_keys AS dek
        ON db.database_id = dek.database_id
    WHERE ISNULL(dek.encryption_state, -1) IN (2,3,4,5,6)
);

-- Count encrypted DBs missing a matching certificate (by thumbprint)
DECLARE @missingEncryptorsCount INT = (
    SELECT COUNT(*)
    FROM sys.databases AS db
    JOIN sys.dm_database_encryption_keys AS dek
        ON db.database_id = dek.database_id
    LEFT JOIN master.sys.certificates c
        ON dek.encryptor_type = 'CERTIFICATE'
       AND c.thumbprint = dek.encryptor_thumbprint
    WHERE ISNULL(dek.encryption_state, -1) IN (2,3,4,5,6)
      AND dek.encryptor_type = 'CERTIFICATE'
      AND c.name IS NULL
);

-- Count encrypted DBs whose certificate exists but does NOT have the expected name
DECLARE @wrongProtectorCount INT = (
    SELECT COUNT(*)
    FROM sys.databases AS db
    JOIN sys.dm_database_encryption_keys AS dek
        ON db.database_id = dek.database_id
    LEFT JOIN master.sys.certificates c
        ON dek.encryptor_type = 'CERTIFICATE'
       AND c.thumbprint = dek.encryptor_thumbprint
    WHERE ISNULL(dek.encryption_state, -1) IN (2,3,4,5,6)
      AND dek.encryptor_type = 'CERTIFICATE'
      AND c.name IS NOT NULL
      AND c.name <> @CertName
);

DECLARE @msgs NVARCHAR(MAX) = N'';
DECLARE @hasError BIT = 0;

-- AG expectations per instance
DECLARE @minAg INT = TRY_CONVERT(INT, '$(ExpectedAGMin)');
DECLARE @maxAg INT = TRY_CONVERT(INT, '$(ExpectedAGMax)');

IF @minAg IS NULL SET @minAg = 0;
IF @maxAg IS NULL SET @maxAg = 2147483647;

IF NOT (@agCount BETWEEN @minAg AND @maxAg)
BEGIN
    SET @msgs = @msgs + 'Invalid AG setup (' + CAST(@agCount AS NVARCHAR(10)) + '); ';
    SET @hasError = 1;
END

IF @agCount > 0 AND @isHadr = 0
BEGIN
    SET @msgs = @msgs + 'HADR disabled but AG(s) exist; ';
    SET @hasError = 1;
END

-- Expected certificate by name present in master?
IF @certExists = 0
BEGIN
    SET @msgs = @msgs + 'Certificate ''' + @CertName + ''' NOT FOUND; ';
    SET @hasError = 1;
END

-- Encrypted DBs checks (only add error text when problems exist)
IF @encryptedDbCount > 0
BEGIN
    IF @missingEncryptorsCount > 0
    BEGIN
        SET @msgs = @msgs + 'Missing encryptor for ' + CAST(@missingEncryptorsCount AS NVARCHAR(10)) + ' encrypted DB(s); ';
        SET @hasError = 1;
    END

    IF @wrongProtectorCount > 0
    BEGIN
        SET @msgs = @msgs + CAST(@wrongProtectorCount AS NVARCHAR(10)) + ' encrypted DB(s) not protected by ''' + @CertName + '''; ';
        SET @hasError = 1;
    END
END

-- If any logical error found: print once and HALT script via THROW
IF @hasError = 1
BEGIN
    PRINT 'ERROR: ' + @inst + ' -> ' + @msgs;
    -- THROW a user error (severity 16) to trigger :ON ERROR EXIT
    THROW 51000, 'Health check failed. Halting script.', 1;
END
"

-- ===== Instance 1 =====
:CONNECT $(Inst1)
:setvar ExpectedAGMin $(Inst1ExpectedAGMin)
:setvar ExpectedAGMax $(Inst1ExpectedAGMax)
DECLARE @CertName sysname = N'$(CertName)';
$(CheckBlock)
GO

-- ===== Instance 2 =====
:CONNECT $(Inst2)
:setvar ExpectedAGMin $(Inst2ExpectedAGMin)
:setvar ExpectedAGMax $(Inst2ExpectedAGMax)
DECLARE @CertName sysname = N'$(CertName)';
$(CheckBlock)
GO

-- ===== Instance 3 =====
:CONNECT $(Inst3)
:setvar ExpectedAGMin $(Inst3ExpectedAGMin)
:setvar ExpectedAGMax $(Inst3ExpectedAGMax)
DECLARE @CertName sysname = N'$(CertName)';
$(CheckBlock)
GO

-- ===== Instance 4 =====
:CONNECT $(Inst4)
:setvar ExpectedAGMin $(Inst4ExpectedAGMin)
:setvar ExpectedAGMax $(Inst4ExpectedAGMax)
DECLARE @CertName sysname = N'$(CertName)';
$(CheckBlock)
GO
