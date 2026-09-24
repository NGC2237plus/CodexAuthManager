// Small local GUI host for the WPF/PowerShell application. No network code.
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;

internal static class Launcher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "CodexAuthManager.ps1");
            var state = InitialSessionState.CreateDefault();
            // Process-local execution policy; do not modify machine/user policy.
            state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (var runspace = RunspaceFactory.CreateRunspace(state))
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddCommand(script);
                    for (int i = 0; i < args.Length; i++)
                    {
                        if (args[i].Equals("-Demo", StringComparison.OrdinalIgnoreCase))
                            ps.AddParameter("Demo", true);
                        else if (args[i].Equals("-SmokeTest", StringComparison.OrdinalIgnoreCase))
                            ps.AddParameter("SmokeTest", true);
                        else if ((args[i].Equals("-ReportPath", StringComparison.OrdinalIgnoreCase) ||
                                  args[i].Equals("-CodexDir", StringComparison.OrdinalIgnoreCase)) && i + 1 < args.Length)
                        {
                            string name = args[i].Substring(1);
                            ps.AddParameter(name, args[++i]);
                        }
                        else throw new ArgumentException("Unsupported argument");
                    }
                    ps.Invoke();
                    if (ps.HadErrors) throw new InvalidOperationException("Application error");
                }
            }
            return 0;
        }
        catch
        {
            // Do not display raw PowerShell errors, paths to credentials or tokens.
            MessageBox.Show("Unable to start the interface. Check that all application files are present. You can still use codex-auth-manager.bat.",
                "Codex Account Manager", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
