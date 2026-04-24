function fish_greeting
    if test -z "$BW_SESSION"
        echo "Bitwarden locked. Run: export BW_SESSION=(bw unlock --raw)"
        return
    end

    if not bw unlock --check >/dev/null 2>/dev/null
        echo "Bitwarden session expired. Run: export BW_SESSION=(bw unlock --raw)"
    end
end