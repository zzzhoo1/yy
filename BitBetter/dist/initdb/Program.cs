using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Loader;
using Microsoft.Extensions.DependencyInjection;

// Standalone DB initializer for the patched Bitwarden services (no Docker).
//
// Creates the SQLite schema (EnsureCreated) and optionally inserts a test user
// with a DataProtection-encrypted master password that Identity can verify.
//
// Configuration via environment variables (all optional, sensible defaults):
//   BW_APP_DIR      - directory containing the extracted Identity app DLLs (default /tmp/fs-identity/app)
//   BW_DATA_DIR     - directory for the SQLite DB + DataProtection key ring (default /tmp/bw-data)
//   BW_EMAIL        - test user email (default test@example.com)
//   BW_PASSWORD     - test user master password (default password123)
//   BW_KEY          - test user encryption key (default test-key)
//   BW_INSERT_USER  - "1" to insert the test user, "0" to only create schema (default 1)
//
// Must be run from a directory that can resolve Microsoft.Extensions 10.0 assemblies,
// and initdb.dll must be copied next to the app DLLs so OnResolve can find them.
class InitDb
{
    static string AppDir = Env("BW_APP_DIR", "/tmp/fs-identity/app");
    static string DataDir = Env("BW_DATA_DIR", "/tmp/bw-data");
    static string Email = Env("BW_EMAIL", "test@example.com");
    static string Password = Env("BW_PASSWORD", "password123");
    static string UserKey = Env("BW_KEY", "test-key");
    static bool InsertUser = Env("BW_INSERT_USER", "1") == "1";

    static string DbPath => Path.Combine(DataDir, "bw.db");
    static string KeysDir => Path.Combine(DataDir, "dp-keys");

    static string Env(string name, string def) =>
        Environment.GetEnvironmentVariable(name) is string v && v.Length > 0 ? v : def;

    static Assembly OnResolve(AssemblyLoadContext context, AssemblyName assemblyName)
    {
        try
        {
            var name = assemblyName.Name + ".dll";
            var path = Path.Combine(AppDir, name);
            if (File.Exists(path)) return Assembly.LoadFrom(path);
        }
        catch (Exception e) { Console.Error.WriteLine("OnResolve EXC " + assemblyName.Name + ": " + e.Message); }
        return null;
    }

    static void Main()
    {
        AssemblyLoadContext.Default.Resolving += OnResolve;
        try
        {
            Run();
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("EXC: " + e);
            Console.Error.Flush();
        }
    }

    static void Run()
    {
        Directory.CreateDirectory(DataDir);
        Directory.CreateDirectory(KeysDir);

        var efAsm = Assembly.LoadFrom(Path.Combine(AppDir, "Infrastructure.EntityFramework.dll"));
        Type ctxType = null;
        foreach (var t in efAsm.GetTypes()) if (t.Name == "DatabaseContext") { ctxType = t; break; }
        Console.Error.WriteLine("ctxType=" + ctxType);

        var services = new ServiceCollection();
        var dpAsm = Assembly.LoadFrom(Path.Combine(AppDir, "Microsoft.AspNetCore.DataProtection.dll"));
        var dpExt = dpAsm.GetType("Microsoft.Extensions.DependencyInjection.DataProtectionServiceCollectionExtensions");
        var addDP = dpExt.GetMethod("AddDataProtection", new[] { typeof(IServiceCollection) });
        var dpBuilder = addDP.Invoke(null, new object[] { services });
        var dpBuilderExt = dpAsm.GetType("Microsoft.AspNetCore.DataProtection.DataProtectionBuilderExtensions");
        var persistMethod = dpBuilderExt.GetMethod("PersistKeysToFileSystem", new[] { dpBuilder.GetType(), typeof(DirectoryInfo) });
        persistMethod.Invoke(null, new object[] { dpBuilder, new DirectoryInfo(KeysDir) });
        // Must match Identity's application name, or DataProtection keys won't match.
        var setAppName = dpBuilderExt.GetMethod("SetApplicationName", new[] { dpBuilder.GetType(), typeof(string) });
        setAppName.Invoke(null, new object[] { dpBuilder, "Bitwarden" });

        var sqliteSvcAsm = Assembly.LoadFrom(Path.Combine(AppDir, "Microsoft.EntityFrameworkCore.Sqlite.dll"));
        var sqliteSvcExt = sqliteSvcAsm.GetType("Microsoft.Extensions.DependencyInjection.SqliteServiceCollectionExtensions");
        var addEF = sqliteSvcExt.GetMethod("AddEntityFrameworkSqlite", new[] { typeof(IServiceCollection) });
        addEF.Invoke(null, new object[] { services });
        var sp = services.BuildServiceProvider();

        var efCoreAsm = Assembly.LoadFrom(Path.Combine(AppDir, "Microsoft.EntityFrameworkCore.dll"));
        var builderGenType = efCoreAsm.GetType("Microsoft.EntityFrameworkCore.DbContextOptionsBuilder`1");
        var optionsType = builderGenType.MakeGenericType(ctxType);
        var builder = Activator.CreateInstance(optionsType);
        var sqliteAsm = Assembly.LoadFrom(Path.Combine(AppDir, "Microsoft.EntityFrameworkCore.Sqlite.dll"));
        var extType = sqliteAsm.GetType("Microsoft.EntityFrameworkCore.SqliteDbContextOptionsBuilderExtensions");
        MethodInfo useSqlite = null;
        foreach (var m in extType.GetMethods(BindingFlags.Public | BindingFlags.Static))
        {
            if (m.Name != "UseSqlite") continue;
            var ps = m.GetParameters();
            if (ps.Length == 3 && ps[0].ParameterType.IsGenericType && ps[1].ParameterType == typeof(string))
            { useSqlite = m; break; }
        }
        useSqlite = useSqlite.MakeGenericMethod(ctxType);
        var bwp = useSqlite.Invoke(null, new object[] { builder, "Data Source=" + DbPath, null });
        var useInternal = optionsType.GetMethod("UseInternalServiceProvider", new[] { typeof(IServiceProvider) });
        useInternal.Invoke(bwp, new object[] { sp });
        PropertyInfo optionsProp = null;
        foreach (var p in bwp.GetType().GetProperties())
            if (p.Name == "Options" && !p.PropertyType.IsInterface) { optionsProp = p; break; }
        var options = optionsProp.GetValue(bwp);
        var ctor = ctxType.GetConstructor(new[] { options.GetType() });
        var ctx = ctor.Invoke(new object[] { options });
        var database = ctxType.GetProperty("Database").GetValue(ctx);
        var ec = database.GetType().GetMethod("EnsureCreated", Type.EmptyTypes);
        var created = (bool)ec.Invoke(database, null);
        Console.Error.WriteLine("EnsureCreated = " + created);

        if (!InsertUser)
        {
            Console.Error.WriteLine("Schema created (no user inserted).");
            Console.Error.Flush();
            return;
        }

        var dpAbsAsm = Assembly.LoadFrom(Path.Combine(AppDir, "Microsoft.AspNetCore.DataProtection.Abstractions.dll"));
        var dpProvider = sp.GetService(dpAbsAsm.GetType("Microsoft.AspNetCore.DataProtection.IDataProtectionProvider"));
        var createProtector = dpProvider.GetType().GetMethod("CreateProtector", new[] { typeof(string) });
        var protector = createProtector.Invoke(dpProvider, new object[] { "DatabaseFieldProtection" });
        var dpCommonExt = dpAbsAsm.GetType("Microsoft.AspNetCore.DataProtection.DataProtectionCommonExtensions");
        var idpType = dpAbsAsm.GetType("Microsoft.AspNetCore.DataProtection.IDataProtector");
        var protectMethod = dpCommonExt.GetMethod("Protect", new[] { idpType, typeof(string) });

        var efModelsAsm = Assembly.LoadFrom(Path.Combine(AppDir, "Infrastructure.EntityFramework.dll"));
        Type userType = null;
        foreach (var t in efModelsAsm.GetTypes()) if (t.Name == "User") { userType = t; break; }
        var identityCoreAsm = Assembly.LoadFrom(Path.Combine(AppDir, "Microsoft.Extensions.Identity.Core.dll"));
        var hasherGen = identityCoreAsm.GetType("Microsoft.AspNetCore.Identity.PasswordHasher`1");
        var hasherType = hasherGen.MakeGenericType(userType);
        var phoType = identityCoreAsm.GetType("Microsoft.AspNetCore.Identity.PasswordHasherOptions");
        var pho = Activator.CreateInstance(phoType);
        var optionsGen = typeof(Microsoft.Extensions.Options.Options).GetMethods()
            .First(m => m.Name == "Create" && m.IsGenericMethodDefinition);
        optionsGen = optionsGen.MakeGenericMethod(phoType);
        var ioptions = optionsGen.Invoke(null, new object[] { pho });
        var ctorInfo = hasherType.GetConstructor(new[] { ioptions.GetType() });
        var hasher = ctorInfo.Invoke(new object[] { ioptions });
        var hashMethod = hasherType.GetMethod("HashPassword", new[] { userType, typeof(string) });

        var user = Activator.CreateInstance(userType);
        var now = DateTime.UtcNow;
        userType.GetProperty("Id").SetValue(user, Guid.NewGuid());
        userType.GetProperty("Email").SetValue(user, Email);
        userType.GetProperty("EmailVerified").SetValue(user, true);
        userType.GetProperty("Culture").SetValue(user, "en-US");
        userType.GetProperty("SecurityStamp").SetValue(user, Guid.NewGuid().ToString());
        var kdfType = Assembly.LoadFrom(Path.Combine(AppDir, "Core.dll")).GetType("Bit.Core.Enums.KdfType");
        var kdfEnum = Enum.Parse(kdfType, "PBKDF2_SHA256");
        userType.GetProperty("Kdf").SetValue(user, kdfEnum);
        userType.GetProperty("KdfIterations").SetValue(user, 600000);
        userType.GetProperty("CreationDate").SetValue(user, now);
        userType.GetProperty("RevisionDate").SetValue(user, now);
        userType.GetProperty("AccountRevisionDate").SetValue(user, now);
        userType.GetProperty("LastPasswordChangeDate").SetValue(user, now);
        userType.GetProperty("Premium").SetValue(user, true);
        userType.GetProperty("ApiKey").SetValue(user, Guid.NewGuid().ToString());

        var plainHash = (string)hashMethod.Invoke(hasher, new object[] { user, Password });
        var encHash = "P|" + (string)protectMethod.Invoke(null, new object[] { protector, plainHash });
        var encKey = "P|" + (string)protectMethod.Invoke(null, new object[] { protector, UserKey });
        userType.GetProperty("MasterPassword").SetValue(user, encHash);
        userType.GetProperty("Key").SetValue(user, encKey);

        var usersProp = ctxType.GetProperty("Users");
        var users = usersProp.GetValue(ctx);
        var addAsync = users.GetType().GetMethod("AddAsync", new[] { userType, typeof(System.Threading.CancellationToken) });
        var addValueTask = addAsync.Invoke(users, new object[] { user, System.Threading.CancellationToken.None });
        var asTask = addValueTask.GetType().GetMethod("AsTask");
        var addTask = (System.Threading.Tasks.Task)asTask.Invoke(addValueTask, null);
        addTask.GetAwaiter().GetResult();
        var saveChanges = ctxType.GetMethod("SaveChangesAsync", Type.EmptyTypes)
            ?? ctxType.GetMethod("SaveChangesAsync", new[] { typeof(System.Threading.CancellationToken) });
        var saveTask = saveChanges.GetParameters().Length == 0
            ? (System.Threading.Tasks.Task)saveChanges.Invoke(ctx, null)
            : (System.Threading.Tasks.Task)saveChanges.Invoke(ctx, new object[] { System.Threading.CancellationToken.None });
        saveTask.GetAwaiter().GetResult();
        Console.Error.WriteLine("User inserted: " + Email);
        Console.Error.Flush();
    }
}
