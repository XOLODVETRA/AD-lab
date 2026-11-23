<#
.SYNOPSIS
    Создаёт дерево подразделений (OU) для учебного домена Active Directory.

.DESCRIPTION
    Создаёт подразделения Lab, Lab\Users с отделами IT, Finance, Sales, Support,
    а также Lab\Groups и Lab\Computers с подразделениями Servers и Workstations.
    Скрипт идемпотентен: уже существующие подразделения пропускаются.

.PARAMETER DomainDN
    Различающееся имя корня домена. По умолчанию: DC=lab,DC=local.

.EXAMPLE
    .\New-LabOUs.ps1

    Создаёт дерево подразделений в домене lab.local.

.EXAMPLE
    .\New-LabOUs.ps1 -DomainDN 'DC=corp,DC=local' -WhatIf

    Показывает, какие подразделения были бы созданы, ничего не меняя.
#>
#Requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$DomainDN = 'DC=lab,DC=local'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 1. Модуль ActiveDirectory
if (-not (Get-Module -ListAvailable -Name 'ActiveDirectory')) {
    $ErrorActionPreference = 'Continue'
    Write-Error 'Нужен модуль ActiveDirectory: запускайте на контроллере домена или с RSAT.'
    exit 1
}

function Get-OuDN {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$RootDN
    )

    if ([string]::IsNullOrEmpty($RelativePath)) {
        return $RootDN
    }

    $parts = $RelativePath.Split('\')
    $dnParts = @()
    for ($i = $parts.Length - 1; $i -ge 0; $i--) {
        $dnParts += 'OU=' + $parts[$i]
    }

    return (($dnParts -join ',') + ',' + $RootDN)
}

$relativePaths = @(
    'Lab'
    'Lab\Users'
    'Lab\Users\IT'
    'Lab\Users\Finance'
    'Lab\Users\Sales'
    'Lab\Users\Support'
    'Lab\Groups'
    'Lab\Computers'
    'Lab\Computers\Servers'
    'Lab\Computers\Workstations'
)

$created = 0
$existed = 0

try {
    foreach ($relativePath in $relativePaths) {
        $parts = $relativePath.Split('\')
        $ouName = $parts[$parts.Length - 1]

        $parentRelativePath = ''
        if ($parts.Length -gt 1) {
            $parentRelativePath = ($parts[0..($parts.Length - 2)] -join '\')
        }

        $ouDn = Get-OuDN -RelativePath $relativePath -RootDN $DomainDN
        $parentDn = Get-OuDN -RelativePath $parentRelativePath -RootDN $DomainDN

        $existing = Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDn'" -ErrorAction SilentlyContinue

        if ($null -ne $existing) {
            $existed++
            Write-Verbose "Подразделение уже существует: $ouDn"
            Write-Host "Уже существует: $ouDn"
            continue
        }

        if ($PSCmdlet.ShouldProcess($ouDn, 'Создать подразделение')) {
            New-ADOrganizationalUnit -Name $ouName -Path $parentDn -Description ('Лабораторное подразделение ' + $ouName)
            $created++
            Write-Verbose "Создано подразделение: $ouDn"
        }
    }
}
catch {
    $ErrorActionPreference = 'Continue'
    Write-Error ('Не удалось создать подразделения: ' + $_.Exception.Message)
    exit 1
}

if ($WhatIfPreference) {
    Write-Host 'Режим -WhatIf: изменения не вносились.'
}

Write-Host ("Создано подразделений: {0}, уже было: {1}" -f $created, $existed)
