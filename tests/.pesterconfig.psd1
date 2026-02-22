@{
    Run = @{
        Path = './tests'
        Exit = $true
    }
    Output = @{
        Verbosity = 'Detailed'
        StackTraceVerbosity = 'Full'
    }
    Filter = @{
        # Use -Tag / -ExcludeTag at invocation to select suites:
        #   Invoke-Pester -Tag Unit
        #   Invoke-Pester -Tag Integration
        #   Invoke-Pester -Tag RealRemote
        #   Invoke-Pester -Tag E2E           (full container lifecycle)
    }
    TestResult = @{
        Enabled      = $true
        OutputFormat  = 'NUnitXml'
        OutputPath    = './artifacts/TestResults.xml'
    }
    CodeCoverage = @{
        Enabled    = $false
        Path       = './current_version/IMPACT_Docker_GUI.psm1'
        OutputPath = './artifacts/Coverage.xml'
    }
}
