import Foundation

/// Small session-scoped shell protocol. Reports are data, never executable text.
public enum SSHDirectoryIntegration {
    public static let osc = 777
    public enum Report: Equatable, Sendable { case prompt(serial: UInt64, path: Data), unavailable }
    public static func decode(_ bytes: ArraySlice<UInt8>, token: String) -> Report? {
        guard bytes.count <= 24_000, let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "Retriever", parts[1] == token else { return nil }
        if parts.count == 3, parts[2] == "U" { return .unavailable }
        guard parts.count == 5, parts[2] == "P", let serial = UInt64(parts[3]), serial > 0,
              let path = Data(base64Encoded: String(parts[4])), validPath(path) else { return nil }
        return .prompt(serial: serial, path: path)
    }
    public static func validPath(_ path: Data) -> Bool {
        guard path.count <= 16_384, let text = String(data: path, encoding: .utf8), text.hasPrefix("/") else { return false }
        return !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    public static func changeDirectory(_ path: Data) -> String? {
        guard validPath(path), let text = String(data: path, encoding: .utf8) else { return nil }
        return "builtin cd -- " + SSHLaunchRequest.quote(text) + "\r"
    }

    public static func launchCommand(folder: String, token: String) -> String {
        let bash = bashScript.replacingOccurrences(of: "__TOKEN__", with: token)
        let zsh = zshScript.replacingOccurrences(of: "__TOKEN__", with: token)
        // The remote login shell parses this command. All generated script bytes
        // and user paths are literal shell arguments, never interpolated as code.
        return "cd " + SSHLaunchRequest.quote(folder) + " || exit 255\n" + """
        _retriever_shell=${SHELL:-/bin/sh}
        case "$_retriever_shell" in
          */bash|*/zsh) ;;
          *) printf '\\033]777;Retriever;\(token);U\\007'; exec "$_retriever_shell" -i ;;
        esac
        command -v base64 >/dev/null 2>&1 || { printf '\\033]777;Retriever;\(token);U\\007'; exec "$_retriever_shell" -i; }
        _retriever_dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/retriever-shell.XXXXXXXX") || exit 255
        trap 'rm -rf -- "$_retriever_dir"' 0
        printf '%s' \(SSHLaunchRequest.quote(bash)) > "$_retriever_dir/bashrc" || exit 255
        printf '%s' \(SSHLaunchRequest.quote(zshEnvScript)) > "$_retriever_dir/.zshenv" || exit 255
        printf '%s' \(SSHLaunchRequest.quote(zsh)) > "$_retriever_dir/.zshrc" || exit 255
        case "$_retriever_shell" in
          */bash) RETRIEVER_SHIM_DIR="$_retriever_dir" "$_retriever_shell" --rcfile "$_retriever_dir/bashrc" -i ;;
          */zsh) RETRIEVER_ORIGINAL_ZDOTDIR="${ZDOTDIR-$HOME}" RETRIEVER_SHIM_DIR="$_retriever_dir" ZDOTDIR="$_retriever_dir" "$_retriever_shell" -i ;;
        esac
        _retriever_exit=$?
        exit "$_retriever_exit"
        """
    }

    private static let bashScript = #"""
    [ ! -r "$HOME/.bashrc" ] || . "$HOME/.bashrc"
    _retriever_token=__TOKEN__
    _retriever_owner=$$
    _retriever_serial=0
    _retriever_suffix=''
    _retriever_prompt() {
      local _retriever_result=$?
      [ "$$" = "$_retriever_owner" ] || return "$_retriever_result"
      PS1=${PS1%"$_retriever_suffix"}
      _retriever_serial=$((_retriever_serial + 1))
      local _retriever_path
      local _retriever_directory
      _retriever_directory=$(builtin pwd -P; printf '.')
      _retriever_directory=${_retriever_directory%.}
      _retriever_directory=${_retriever_directory%$'\n'}
      _retriever_path=$(printf '%s' "$_retriever_directory" | base64 | tr -d '\r\n')
      printf -v _retriever_suffix '\[\e]777;Retriever;%s;P;%s;%s\a\]' "$_retriever_token" "$_retriever_serial" "$_retriever_path"
      PS1="${PS1}${_retriever_suffix}"
      return "$_retriever_result"
    }
    case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
      'declare -a '*) PROMPT_COMMAND+=(_retriever_prompt) ;;
      *) PROMPT_COMMAND="${PROMPT_COMMAND-}
    _retriever_prompt" ;;
    esac
    command rm -rf -- "$RETRIEVER_SHIM_DIR"
    unset RETRIEVER_SHIM_DIR
    """#
    private static let zshEnvScript = #"""
    ZDOTDIR=$RETRIEVER_ORIGINAL_ZDOTDIR
    [[ ! -r "$ZDOTDIR/.zshenv" ]] || source "$ZDOTDIR/.zshenv"
    _retriever_actual_zdotdir=${ZDOTDIR-$HOME}
    ZDOTDIR=$RETRIEVER_SHIM_DIR
    unset RETRIEVER_ORIGINAL_ZDOTDIR
    """#
    private static let zshScript = #"""
    ZDOTDIR=$_retriever_actual_zdotdir
    [[ ! -r "$ZDOTDIR/.zshrc" ]] || source "$ZDOTDIR/.zshrc"
    _retriever_token=__TOKEN__
    _retriever_owner=$$
    _retriever_serial=0
    _retriever_prompt() {
      [[ $$ = $_retriever_owner && $CONTEXT = start && -z $BUFFER ]] || return 0
      _retriever_serial=$((_retriever_serial + 1))
      local _retriever_directory _retriever_path
      _retriever_directory=$(builtin pwd -P; printf '.')
      _retriever_directory=${_retriever_directory%.}
      _retriever_directory=${_retriever_directory%$'\n'}
      _retriever_path=$(printf '%s' "$_retriever_directory" | base64 | tr -d '\r\n')
      printf '\e]777;Retriever;%s;P;%s;%s\a' "$_retriever_token" "$_retriever_serial" "$_retriever_path"
      return 0
    }
    autoload -Uz add-zle-hook-widget
    add-zle-hook-widget line-init _retriever_prompt || printf '\e]777;Retriever;%s;U\a' "$_retriever_token"
    command rm -rf -- "$RETRIEVER_SHIM_DIR"
    unset RETRIEVER_SHIM_DIR _retriever_actual_zdotdir
    """#
}

/// Deliberately does not reconstruct readline/ZLE input. Ambiguous typeahead
/// requires a new empty Return after the shell prompt has returned.
public struct SSHPromptGate: Sendable {
    public private(set) var ready = false
    public private(set) var lastSerial: UInt64 = 0
    private var sawPrompt = false
    private var submittedLines = 0
    private var inputAfterSubmission = false
    private var initialInput = false
    public init() {}
    public mutating func input(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        ready = false
        if !sawPrompt { initialInput = true }
        if submittedLines > 0 { inputAfterSubmission = true }
        // Only a separate Return is an unambiguous submission. Bracketed paste,
        // multi-line input and program replies remain conservatively paused.
        if bytes.count == 1, bytes.first == 13 { submittedLines += 1 }
    }
    @discardableResult public mutating func prompt(serial: UInt64) -> Bool {
        guard serial > lastSerial else { return false }
        lastSerial = serial
        ready = (!sawPrompt && !initialInput) || (sawPrompt && submittedLines == 1 && !inputAfterSubmission)
        sawPrompt = true
        submittedLines = 0
        inputAfterSubmission = false
        return true
    }
    public mutating func sentDirectoryChange() {
        ready = false
        submittedLines = 1
        inputAfterSubmission = false
    }
}
