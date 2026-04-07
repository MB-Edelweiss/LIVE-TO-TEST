# Updated PowerShell Script

# Contains the rest of the script that you want to keep.

# Replace the specific line
$cmd = "docker exec $($Config.DockerWebContainer) bash -lc 'if [ -d \"$target\" ]; then mv \"$target\" \"$disabled\"; fi'"