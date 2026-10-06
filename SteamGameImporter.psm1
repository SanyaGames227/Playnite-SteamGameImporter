function Get-SteamInstallDir
{
    param([string]$AppId)

    # Find Steam path and all library folders
    $steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (!$steamPath) { return $null }
    $steamPath = $steamPath -replace '/', '\'

    $libraries = @($steamPath)
    $vdf = Join-Path $steamPath "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf)
    {
        foreach ($line in [System.IO.File]::ReadAllLines($vdf)) {
            if ($line -match '"path"\s+"([^"]+)"')
            {
                $libraries += ($Matches[1] -replace '\\\\', '\')
            }
        }
    }

    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $manifest = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path $manifest)) { continue }
        foreach ($line in [System.IO.File]::ReadAllLines($manifest)) {
            if ($line -match '"installdir"\s+"([^"]+)"')
            {
                $dir = Join-Path $lib ("steamapps\common\" + $Matches[1])
                if (Test-Path $dir) { return $dir }
            }
        }
    }
    return $null
}

function FixInstalledState
{
    param($scriptMainMenuItemActionArgs)

    $steamPluginId = [Playnite.SDK.BuiltinExtensions]::GetIdFromExtension([Playnite.SDK.BuiltinExtension]::SteamLibrary)
    $fixed = 0
    foreach ($game in $PlayniteApi.Database.Games) {
        if ($game.PluginId -ne $steamPluginId) { continue }
        if ($game.IsInstalled -and $game.InstallDirectory) { continue }
        $dir = Get-SteamInstallDir -AppId $game.GameId
        if (!$dir) { continue }
        $game.InstallDirectory = $dir
        $game.IsInstalled = $true
        $PlayniteApi.Database.Games.Update($game)
        $fixed++
    }
    $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_FixInstalledStateResultsMessage") -f $fixed), "Steam Game Importer")
}

function Get-SteamLibraryPaths
{
    $steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (!$steamPath) { return @() }
    $steamPath = $steamPath -replace '/', '\'

    $libraries = @($steamPath)
    $vdf = Join-Path $steamPath "steamapps\libraryfolders.vdf"
    if (Test-Path $vdf)
    {
        foreach ($line in [System.IO.File]::ReadAllLines($vdf)) {
            if ($line -match '"path"\s+"([^"]+)"')
            {
                $libraries += ($Matches[1] -replace '\\\\', '\')
            }
        }
    }
    # Registry gives "c:\steam", vdf gives "C:\Steam": compare case-insensitively
    $seen = @{}
    $result = @()
    foreach ($l in $libraries) {
        $n = $l.TrimEnd('\')
        $key = $n.ToLowerInvariant()
        if (-not $seen.ContainsKey($key))
        {
            $seen[$key] = $true
            $result += $n
        }
    }
    return $result
}

function Get-InstalledSteamApps
{
    $apps = @()
    $ignoreRegex = 'Steamworks Common Redistributables|Steam Linux Runtime|Proton|Steam Controller Configs'

    foreach ($lib in (Get-SteamLibraryPaths)) {
        $steamapps = Join-Path $lib "steamapps"
        if (-not (Test-Path $steamapps)) { continue }

        foreach ($file in (Get-ChildItem -Path $steamapps -Filter "appmanifest_*.acf" -ErrorAction SilentlyContinue)) {
            $appId = $null; $name = $null; $installDir = $null; $flags = 0
            foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
                if ($line -match '"appid"\s+"(\d+)"') { $appId = $Matches[1] }
                elseif ($line -match '"name"\s+"(.*)"') { $name = $Matches[1] -replace '\\"', '"' }
                elseif ($line -match '"installdir"\s+"(.*)"') { $installDir = $Matches[1] }
                elseif ($line -match '"StateFlags"\s+"(\d+)"') { $flags = [int]$Matches[1] }
            }
            if (!$appId -or !$name -or !$installDir) { continue }
            # Only fully installed apps (flag 4), skip tools and runtimes
            if (($flags -band 4) -ne 4) { continue }
            if ($appId -eq "228980" -or $name -match $ignoreRegex) { continue }

            $dir = Join-Path $steamapps ("common\" + $installDir)
            $apps += [pscustomobject]@{ AppId = $appId; Name = $name; InstallDir = $dir }
        }
    }
    # One entry per AppId
    $unique = @{}
    foreach ($a in $apps) {
        if (-not $unique.ContainsKey($a.AppId)) { $unique[$a.AppId] = $a }
    }
    return @($unique.Values)
}

function ImportInstalledSteamGames
{
    param($scriptMainMenuItemActionArgs)

    $steamPluginId = [Playnite.SDK.BuiltinExtensions]::GetIdFromExtension([Playnite.SDK.BuiltinExtension]::SteamLibrary)
    $existing = Get-SteamGamesInLibrary
    $apps = @(Get-InstalledSteamApps | Where-Object { $null -eq $existing[$_.AppId] } | Sort-Object Name)

    if ($apps.Count -eq 0)
    {
        $PlayniteApi.Dialogs.ShowMessage([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_NoNewInstalledGamesMessage"), "Steam Game Importer")
        return
    }

    # Build the selection window
    $xaml = @"
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="10">
    <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBox x:Name="SearchBox" Grid.Row="0" Margin="0,0,0,8" Padding="4"/>
    <ListBox x:Name="GamesList" Grid.Row="1"/>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
        <Button x:Name="SelectAllButton" Content="Select all" Padding="12,4" Margin="0,0,8,0"/>
        <Button x:Name="OkButton" Content="Add" Padding="20,4" Margin="0,0,8,0"/>
        <Button x:Name="CancelButton" Content="Cancel" Padding="12,4"/>
    </StackPanel>
</Grid>
"@
    $root = [Windows.Markup.XamlReader]::Parse($xaml)
    $search = $root.FindName("SearchBox")
    $list = $root.FindName("GamesList")
    $btnAll = $root.FindName("SelectAllButton")
    $btnOk = $root.FindName("OkButton")
    $btnCancel = $root.FindName("CancelButton")
    $btnAll.Content = [Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_SelectAllButton")
    $btnOk.Content = [Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_AddButton")
    $btnCancel.Content = [Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_CancelButton")

    foreach ($app in $apps) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = "{0} ({1})" -f $app.Name, $app.AppId
        $cb.Tag = $app
        $cb.Margin = "2"
        [void]$list.Items.Add($cb)
    }

    try {
        $opts = New-Object Playnite.SDK.WindowCreationOptions
        $opts.ShowMinimizeButton = $false
        $opts.ShowMaximizeButton = $false
        $window = $PlayniteApi.Dialogs.CreateWindow($opts)
        $window.Owner = $PlayniteApi.Dialogs.GetCurrentAppWindow()
    } catch {
        $window = New-Object System.Windows.Window
    }
    $window.Title = [Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_InstalledGamesWindowTitle")
    $window.Width = 520
    $window.Height = 620
    $window.WindowStartupLocation = "CenterOwner"
    $window.Content = $root

    $search.Add_TextChanged({
        $t = $search.Text
        foreach ($item in $list.Items) {
            if (!$t -or $item.Content -like "*$t*") { $item.Visibility = "Visible" } else { $item.Visibility = "Collapsed" }
        }
    }.GetNewClosure())
    $btnAll.Add_Click({
        foreach ($item in $list.Items) {
            if ($item.Visibility -eq "Visible") { $item.IsChecked = $true }
        }
    }.GetNewClosure())
    $btnOk.Add_Click({ $window.DialogResult = $true }.GetNewClosure())
    $btnCancel.Add_Click({ $window.DialogResult = $false }.GetNewClosure())

    $result = $window.ShowDialog()
    if ($result -ne $true) { return }

    $selected = @($list.Items | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    if ($selected.Count -eq 0) { return }

    $source = $PlayniteApi.Database.Sources.Add("Steam")
    $platform = $PlayniteApi.Database.Platforms.Add("PC (Windows)")
    $platformsList = [System.Collections.Generic.List[guid]]($platform.Id)

    $added = 0
    foreach ($app in $selected) {
        $newGame = New-Object "Playnite.SDK.Models.Game"
        $newGame.Name = $app.Name
        $newGame.GameId = $app.AppId
        $newGame.SourceId = $source.Id
        $newGame.PlatformIds = $platformsList
        $newGame.PluginId = $steamPluginId
        $newGame.InstallDirectory = $app.InstallDir
        $newGame.IsInstalled = $true
        $PlayniteApi.Database.Games.Add($newGame)
        if (Set-GameImagesFromCache -Game $newGame) { $PlayniteApi.Database.Games.Update($newGame) }
        $added++
    }
    $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_ResultsMessage") -f $added), "Steam Game Importer")
}

function Get-SteamCachedImages
{
    param([string]$AppId)

    $result = @{ Cover = $null; Background = $null; Icon = $null }
    $steamPath = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (!$steamPath) { return $result }
    $cache = Join-Path ($steamPath -replace '/', '\') "appcache\librarycache"
    if (-not (Test-Path $cache)) { return $result }

    # Old layout: flat files "<appid>_*.jpg". New layout: folder "<appid>" (files may be in hashed subfolders)
    $files = @()
    $files += Get-ChildItem -Path $cache -File -Filter "$($AppId)_*" -ErrorAction SilentlyContinue
    $appDir = Join-Path $cache $AppId
    if (Test-Path $appDir)
    {
        $files += Get-ChildItem -Path $appDir -File -Recurse -ErrorAction SilentlyContinue
    }
    if ($files.Count -eq 0) { return $result }

    $pick = {
        param($regex)
        $files | Where-Object { $_.Name -match $regex } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }

    $cover = & $pick '(^|_)library_600x900(_2x)?\.(jpg|png)$'
    if (!$cover) { $cover = & $pick '(^|_)header\.(jpg|png)$' }
    $hero = & $pick '(^|_)library_hero\.(jpg|png)$'
    $icon = & $pick '^([0-9a-f]{40}|\d+_icon)\.jpg$'

    if ($cover) { $result.Cover = $cover.FullName }
    if ($hero) { $result.Background = $hero.FullName }
    if ($icon) { $result.Icon = $icon.FullName }
    return $result
}

# Fills only EMPTY image fields. Returns $true if the game was changed (caller must Update it)
function Set-GameImagesFromCache
{
    param($Game)

    $images = Get-SteamCachedImages -AppId $Game.GameId
    $changed = $false
    if ([string]::IsNullOrEmpty($Game.CoverImage) -and $images.Cover)
    {
        $Game.CoverImage = $PlayniteApi.Database.AddFile($images.Cover, $Game.Id)
        $changed = $true
    }
    if ([string]::IsNullOrEmpty($Game.BackgroundImage) -and $images.Background)
    {
        $Game.BackgroundImage = $PlayniteApi.Database.AddFile($images.Background, $Game.Id)
        $changed = $true
    }
    if ([string]::IsNullOrEmpty($Game.Icon) -and $images.Icon)
    {
        $Game.Icon = $PlayniteApi.Database.AddFile($images.Icon, $Game.Id)
        $changed = $true
    }
    return $changed
}

function FillImagesFromCache
{
    param($scriptMainMenuItemActionArgs)

    $steamPluginId = [Playnite.SDK.BuiltinExtensions]::GetIdFromExtension([Playnite.SDK.BuiltinExtension]::SteamLibrary)
    $updated = 0
    foreach ($game in $PlayniteApi.Database.Games) {
        if ($game.PluginId -ne $steamPluginId) { continue }
        if (Set-GameImagesFromCache -Game $game)
        {
            $PlayniteApi.Database.Games.Update($game)
            $updated++
        }
    }
    $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_FillImagesResultsMessage") -f $updated), "Steam Game Importer")
}

function GetMainMenuItems
{
    param(
        $getMainMenuItemsArgs
    )

    $menuItem1 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem1.Description = [Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_MenuItemAddGamesIdUrlDescription")
    $menuItem1.FunctionName = "SteamGameImporter"
    $menuItem1.MenuSection = "@Steam Game Importer"
    
    $menuItem2 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem2.Description = [Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_MenuItemAddGamesDepressurizerDescription")
    $menuItem2.FunctionName = "DepressurizerProfileImporter"
    $menuItem2.MenuSection = "@Steam Game Importer"

    $menuItem3 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem3.Description = [Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_MenuItemFixInstalledStateDescription")
    $menuItem3.FunctionName = "FixInstalledState"
    $menuItem3.MenuSection = "@Steam Game Importer"

    $menuItem4 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem4.Description = [Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_MenuItemImportInstalledDescription")
    $menuItem4.FunctionName = "ImportInstalledSteamGames"
    $menuItem4.MenuSection = "@Steam Game Importer"

    $menuItem5 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem5.Description = [Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_MenuItemFillImagesDescription")
    $menuItem5.FunctionName = "FillImagesFromCache"
    $menuItem5.MenuSection = "@Steam Game Importer"

    return $menuItem4, $menuItem1, $menuItem2, $menuItem3, $menuItem5
}

function DepressurizerProfileImporter
{
    param(
        $scriptMainMenuItemActionArgs
    )
    
    # Ger Depressurizer xml data
    $DepressurizerProfilePath = $PlayniteApi.Dialogs.SelectFile("Profiles|*.Profile")
    if ($DepressurizerProfilePath)
    {
        [xml]$DepressurizerXml = [System.IO.File]::ReadAllLines($DepressurizerProfilePath)
    }
    else
    {
        return
    }
    
    $steamPluginId = [guid]::Parse("cb91dfc9-b977-43bf-8e70-55f46e410fab")
    $source = $PlayniteApi.Database.Sources.Add("Steam")
    $platform = $PlayniteApi.Database.Platforms.Add("PC (Windows)")
    $platformsList = [System.Collections.Generic.List[guid]]($platform.Id)
    $steamGamesInLibrary = Get-SteamGamesInLibrary

    # Create cache of Steam games in Database
    $steamGamesInLibrary = Get-SteamGamesInLibrary

    $addedGamesCount = 0

    foreach ($game in $DepressurizerXml.profile.games.game) {
        
        if ($null -ne $steamGamesInLibrary[$game.id])
        {
            continue
        }
        
        $exclusionItem = $PlayniteApi.Database.ImportExclusions | Where-Object {($_.LibraryId -eq $steamPluginId) -and ($_.GameId -eq $gameid)}
        if ($null -ne $exclusionItem)
        {
            $__logger.Info("Steam game with id $($game.id) is in exclusion list and will be skipped from Depressurizer import")
            continue
        }
        
        # Non game steam apps have an id inferior to 0 in Depressurizer
        if ([int]$game.id -lt 0)
        {
            continue
        }

        # Set game properties and save to database
        $newGame = New-Object "Playnite.SDK.Models.Game"
        $newGame.Name = $game.name
        $newGame.GameId = $game.id
        $newGame.SourceId = $Source.Id
        $newGame.PlatformIds = $platformsList
        $newGame.PluginId = $steamPluginId
        $PlayniteApi.Database.Games.Add($newGame)
        $addedGamesCount++
    }

    # Show dialogue with results
    $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_ResultsMessage") -f $addedGamesCount), "Steam Game Importer")
}

function Get-SteamGamesInLibrary
{
    $steamGamesInLibrary = @{}
    $steamPluginId = [guid]::Parse("cb91dfc9-b977-43bf-8e70-55f46e410fab")
    foreach ($game in $PlayniteApi.Database.Games) {
        if ($game.PluginId -ne $steamPluginId)
        {
            continue
        }

        # Use a try block for safety
        try {
            $steamGamesInLibrary.add($game.GameId, $game.Name)
        } catch {}
    }

    return $steamGamesInLibrary
}

function SteamGameImporter
{
    param(
        $scriptMainMenuItemActionArgs
    )
    
    # Input window for Steam Store URL or Steam AppId
    $UserInput = $PlayniteApi.Dialogs.SelectString([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_RequestInputSteamIdUrlMessage"), "Steam Game Importer", "")
    if (!$UserInput.SelectedString)
    {
        $PlayniteApi.Dialogs.ShowMessage([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_InputNoValidAppIdsMessage"), "Steam Game Importer")
        return
    }
    
    $steamPluginId = [Playnite.SDK.BuiltinExtensions]::GetIdFromExtension([Playnite.SDK.BuiltinExtension]::SteamLibrary)
    $source = $PlayniteApi.Database.Sources.Add("Steam")
    $platform = $PlayniteApi.Database.Platforms.Add("PC (Windows)")
    $platformsList = [System.Collections.Generic.List[guid]]($platform.Id)
    $steamGamesInLibrary = Get-SteamGamesInLibrary

    [System.Collections.Generic.List[string]]$AppIds = @()
    [string]$TextInput = $UserInput.SelectedString		
    $addedGamesCount = 0

    # Verify if input was Steam Store URL
    $UrlRegex = "https?:\/\/store.steampowered.com\/app\/(\d+)"
    if ($TextInput -match $UrlRegex)
    {
        $UrlMatches = $TextInput | Select-String $UrlRegex -AllMatches | Select-Object -Unique
        if ($UrlMatches.Matches.count -ge 1)
        {
            foreach ($UrlMatch in $UrlMatches.Matches) {
                $AppIds.Add($UrlMatch.Groups[1].value)
            }
        }
    }
    # Verify if input was Steam Store AppId
    else
    {
        $TextInput = $TextInput -replace ' ',''
        $TextSplit = $TextInput.Split(',')
        foreach ($SplittedText in $TextSplit) {
            if ($SplittedText -Match "^\d+$")
            {
                $AppIds.Add($SplittedText)
            }
        }
    }
    # Verify if AppId was obtained
    if ($AppIds.count -eq 0)
    {
        $PlayniteApi.Dialogs.ShowMessage([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_InputNoValidAppIdsMessage"), "Steam Game Importer")
        return
    }

    $webClient = New-Object System.Net.WebClient
    $webClient.Encoding = [System.Text.Encoding]::UTF8
    foreach ($AppId in $AppIds) {
        # Skip game if it already exists in Planite game Database
        if ($null -ne $steamGamesInLibrary[$AppId])
        {
            continue
        }

        # Verify is obtained AppId is valid and get game name with SteamAPI
        try {
            $steamAPI = 'https://store.steampowered.com/api/appdetails?appids={0}' -f $AppId
            $downloadedString = $webClient.DownloadString($steamAPI)
            $json = $downloadedString | ConvertFrom-Json
            
            # Sleep time to prevent error 429
            Start-Sleep -Milliseconds 1200
            if ($json.$AppId.Success -eq "true")
            {
                $GameName = $json.$AppId.data.name
            }
            else
            {
                if (!$AddUnknownChoice)
                {
                    $AddUnknownChoice = $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_InvalidSteamIdWarningMessage") -f $AppId), "Steam Game Importer", 4)
                }
                if ($AddUnknownChoice -ne "Yes")
                {
                    continue
                }
                $GameName = "Unknown Steam Game"
            }
        } catch {
            $errorMessage = $_.Exception.Message
            $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_ResultsMessage") -f $AppId, $errorMessage), "Steam Game Importer")
            break
        }
        
        # Set game properties and save to database
        $NewGame = New-Object "Playnite.SDK.Models.Game"
        $NewGame.Name = $GameName
        $NewGame.GameId = $AppId
        $NewGame.SourceId = $Source.Id
        $NewGame.PlatformIds = $platformsList
        $NewGame.PluginId = $steamPluginId

        # Mark as installed if Steam has the game on disk, so Playnite can track the running process
        $installDir = Get-SteamInstallDir -AppId $AppId
        if ($installDir)
        {
            $NewGame.InstallDirectory = $installDir
            $NewGame.IsInstalled = $true
        }
        $PlayniteApi.Database.Games.Add($NewGame)
        if (Set-GameImagesFromCache -Game $NewGame) { $PlayniteApi.Database.Games.Update($NewGame) }
        $addedGamesCount++
        
        # Trigger download Metadata not available yet via SDK. https://github.com/JosefNemec/Playnite/issues/1870
    }
    
    # Show dialogue with results
    $webClient.Dispose()
    $PlayniteApi.Dialogs.ShowMessage(([Playnite.SDK.ResourceProvider]::GetString("LOCSteam_Game_Importer_ResultsMessage") -f $addedGamesCount), "Steam Game Importer")
}