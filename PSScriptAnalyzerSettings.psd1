@{
    # Used by BOTH the VS Code PowerShell extension and the agent's RunPwshAnalysis,
    # so what you see in the Problems panel is what the agent is held to.
    #
    # Severity policy: errors block, warnings are fixed, information is advisory.
    # Deliberately NOT enabled: PSUseShouldProcess (too noisy for utility modules).

    Severity     = @('Error', 'Warning')

    IncludeRules = @(
        # --- correctness ---
        'PSAvoidUsingCmdletAliases'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingEmptyCatchBlock'
        'PSAvoidUsingPositionalParameters'
        'PSAvoidAssignmentToAutomaticVariable'
        'PSAvoidGlobalVars'
        'PSAvoidUsingWriteHost'
        'PSAvoidDefaultValueSwitchParameter'
        'PSAvoidDefaultValueForMandatoryParameter'
        'PSAvoidUsingWMICmdlet'
        'PSReservedCmdletChar'
        'PSReservedParams'
        'PSMisleadingBacktick'
        'PSMissingModuleManifestField'
        'PSPossibleIncorrectComparisonWithNull'
        'PSPossibleIncorrectUsageOfAssignmentOperator'
        'PSPossibleIncorrectUsageOfRedirectionOperator'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUseApprovedVerbs'
        'PSUseCompatibleSyntax'
        'PSUseCompatibleCommands'
        'PSUseCompatibleTypes'
        'PSUseSingularNouns'
        'PSUseOutputTypeCorrectly'
        'PSUseToExportFieldsInManifest'
        'PSUsePSCredentialType'
        'PSUseProcessBlockForPipelineCommand'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSupportsShouldProcess'
        'PSUseLiteralInitializerForHashtable'
        'PSUseCmdletCorrectly'
        'PSAvoidSemicolonsAsLineTerminators'
        'PSAvoidTrailingWhitespace'
        'PSAvoidUsingDoubleQuotesForConstantString'
        'PSPlaceOpenBrace'
        'PSPlaceCloseBrace'
        'PSUseConsistentIndentation'
        'PSUseConsistentWhitespace'
        'PSAlignAssignmentStatement'
        'PSUseCorrectCasing'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            # 5.1 first: it is the stricter parser, so anything that passes here also
            # parses on 7. Add '7.x' versions when you use 7-only features on purpose.
            TargetVersions = @('5.1', '7.0')
        }

        PSUseCompatibleCommands = @{
            Enable         = $false      # expensive; enable per-project when it matters
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }

        PSUseCompatibleTypes = @{
            Enable         = $false
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $true
            CheckSeparator                          = $true
            CheckParameter                          = $true
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }

        PSAvoidUsingWriteHost = @{
            Enable = $true
            # Library code must not use Write-Host. Interactive entry scripts may.
            Whitelist = @()
        }

        PSUseSingularNouns = @{
            Enable      = $true
            # Allowed plurals that read badly in singular form.
            NounWhitelist = @('Data', 'Metadata', 'Information')
        }

        PSUseApprovedVerbs = @{ Enable = $true }

        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
    }
}
