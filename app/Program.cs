using System.Diagnostics;

// SecretConsumer: retrieve a secret from Akeyless at runtime with no credential
// baked into the application.
//
// The only material this process touches is a short-lived Universal Identity
// child token that a separate systemd timer rotates on disk. The token is not a
// password: after each rotation the previous value is permanently rejected, so a
// copy exfiltrated between rotations stops working and the theft surfaces as an
// authentication failure in the Akeyless audit log. The application holds no
// access key, reads no secret from its own configuration, and puts nothing
// sensitive in its environment or command line beyond the rotating token it is
// handed by the platform.

static string Env(string name, string fallback)
    => Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : fallback;

var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
var akeylessBin = Env("AKEYLESS_BIN", "akeyless");
var profile = Env("AKEYLESS_PROFILE", "app-uid");
var tokenFile = Env("UID_TOKEN_FILE",
    Path.Combine(home, ".akeyless-uid", "token", "uid-token"));
var secretName = args.Length > 0 ? args[0] : Env("SECRET_NAME", "/demo/db-password");

if (!File.Exists(tokenFile))
{
    Console.Error.WriteLine($"UID token file not found: {tokenFile}");
    Console.Error.WriteLine("Is the rotation timer installed and has it run at least once?");
    return 2;
}

// Read the current token at call time so we always use the freshest rotation.
var uidToken = (await File.ReadAllTextAsync(tokenFile)).Trim();
if (uidToken.Length == 0)
{
    Console.Error.WriteLine($"UID token file is empty: {tokenFile}");
    return 2;
}

var psi = new ProcessStartInfo
{
    FileName = akeylessBin,
    RedirectStandardOutput = true,
    RedirectStandardError = true,
    UseShellExecute = false,
};
psi.ArgumentList.Add("get-secret-value");
psi.ArgumentList.Add("--name");
psi.ArgumentList.Add(secretName);
psi.ArgumentList.Add("--profile");
psi.ArgumentList.Add(profile);
psi.ArgumentList.Add("--uid-token");
psi.ArgumentList.Add(uidToken);

using var proc = Process.Start(psi)!;
var stdout = await proc.StandardOutput.ReadToEndAsync();
var stderr = await proc.StandardError.ReadToEndAsync();
await proc.WaitForExitAsync();

if (proc.ExitCode != 0)
{
    Console.Error.WriteLine($"akeyless get-secret-value failed (exit {proc.ExitCode}):");
    Console.Error.WriteLine(stderr.Trim());
    return proc.ExitCode;
}

var secret = stdout.Trim();
Console.WriteLine($"Retrieved secret '{secretName}' from Akeyless.");
Console.WriteLine($"Value: {secret}");
Console.WriteLine("No access key or long-lived credential was used or stored by this application.");
return 0;
