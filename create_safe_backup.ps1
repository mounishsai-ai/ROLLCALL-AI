# =============================================================
# AI Attendance System - Safe Backup Script
# Zips the project while excluding all sensitive files.
# =============================================================

$projectPath = "C:\worksapce\AI FACE DETECTION FROM GROUP PHOTO"
$outputZip   = "$env:USERPROFILE\Documents\AI_Attendance_Safe_Backup.zip"
$tempFolder  = "$env:TEMP\AI_Attendance_Backup_Temp"

# Cleanup any previous temp folder
if (Test-Path $tempFolder) { Remove-Item $tempFolder -Recurse -Force }
New-Item -ItemType Directory -Path $tempFolder | Out-Null

Write-Host "Copying project files..." -ForegroundColor Cyan

$excludeFolders = @("build", "__pycache__", "known_faces", ".dart_tool", ".git", "node_modules")
$excludeFiles   = @("serviceAccountKey.json", ".env")

Get-ChildItem -Path $projectPath -Recurse | ForEach-Object {
    foreach ($folder in $excludeFolders) {
        if ($_.FullName -like "*\$folder\*" -or $_.FullName -like "*\$folder") { return }
    }
    foreach ($file in $excludeFiles) {
        if ($_.Name -eq $file) { return }
    }

    $relativePath = $_.FullName.Substring($projectPath.Length + 1)
    $destPath     = Join-Path $tempFolder $relativePath

    if ($_.PSIsContainer) {
        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
    } else {
        $destDir = Split-Path $destPath -Parent
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item $_.FullName -Destination $destPath -Force
    }
}

Write-Host "Creating placeholder files for sensitive data..." -ForegroundColor Yellow

$firebasePlaceholder = '{ "IMPORTANT": "Excluded for security. Go to Firebase Console > Project Settings > Service Accounts > Generate New Private Key", "place_at": "backend/serviceAccountKey.json" }'
$firebasePlaceholder | Out-File -FilePath "$tempFolder\backend\serviceAccountKey.PLACEHOLDER.json" -Encoding UTF8

$envPlaceholder = "# Rename this file to .env`n# AZURE_ENDPOINT=https://your-resource.cognitiveservices.azure.com/`n# AZURE_KEY=your_azure_key_here"
$envPlaceholder | Out-File -FilePath "$tempFolder\backend\.env.example" -Encoding UTF8

New-Item -ItemType Directory -Path "$tempFolder\backend\known_faces" -Force | Out-Null
"Register students via the mobile app to populate this folder." | Out-File "$tempFolder\backend\known_faces\PUT_STUDENT_PHOTOS_HERE.txt" -Encoding UTF8

$readme = "# AI Attendance System - Setup Guide`n`n## Backend Setup`n1. cd backend`n2. py -3.11 -m pip install -r requirements.txt`n3. Place your Firebase serviceAccountKey.json in backend/ folder`n4. py -3.11 -m uvicorn main:app --host 0.0.0.0 --port 8000 --reload`n`n## Mobile App Setup`n1. cd frontend`n2. flutter pub get`n3. flutter build apk --release`n4. Install the APK on your Android phone`n`n## Usage`n1. Make sure phone and laptop are on the SAME WiFi network`n2. Register students with clear face photos`n3. Take a group photo to mark attendance"
$readme | Out-File -FilePath "$tempFolder\README.md" -Encoding UTF8

Write-Host "Creating ZIP file in your Documents folder..." -ForegroundColor Cyan
if (Test-Path $outputZip) { Remove-Item $outputZip -Force }
Compress-Archive -Path "$tempFolder\*" -DestinationPath $outputZip -CompressionLevel Optimal

Remove-Item $tempFolder -Recurse -Force

$zipSize = [math]::Round((Get-Item $outputZip).Length / 1MB, 2)
Write-Host ""
Write-Host "DONE! Safe backup created:" -ForegroundColor Green
Write-Host "   File: $outputZip" -ForegroundColor White
Write-Host "   Size: $zipSize MB" -ForegroundColor White
Write-Host ""
Write-Host "EXCLUDED for security:" -ForegroundColor Red
Write-Host "   - serviceAccountKey.json (Firebase credentials)" -ForegroundColor Red
Write-Host "   - .env (API keys)" -ForegroundColor Red
Write-Host "   - known_faces/ (student face photos)" -ForegroundColor Red
Write-Host "   - build/ folders (saves ~500MB)" -ForegroundColor Red
Write-Host ""
Write-Host "You can now safely upload AI_Attendance_Safe_Backup.zip to Google Drive!" -ForegroundColor Cyan
