# VM-test secrets fixture: a plaintext stand-in for the committed sops
# document, derived at build time from the sanctioned template (the only
# sanctioned source) and encrypted with a dedicated throwaway age key pair.
# The key is generated fresh inside this derivation per build — it never
# enters the repository, and it only ever decrypts fixture values, so its
# appearance in the Nix store of a test closure is harmless by design.
{
  # Nixpkgs package set used by the evaluation that boots the test VM.
  pkgs,
  # Path to the plaintext schema template (secrets/secrets.example.yaml).
  secretsExample,
}:
pkgs.runCommand "homelab-vm-test-secrets"
  {
    nativeBuildInputs = with pkgs; [
      age
      gnused
      sops
    ];
  }
  ''
    mkdir -p "$out"

    age-keygen -o "$out/age.key"
    pub="$(age-keygen -y "$out/age.key")"

    # Give the shared break-glass admin identity a printable form (its email
    # local part becomes the Forgejo username and must be a valid account
    # name); every other placeholder becomes the same inert secret value.
    sed \
      -e 's/ADMIN_EMAIL=\.\.*/ADMIN_EMAIL=fixture-admin@example.test/' \
      -e 's/\.\.\./fixture-secret/g' \
      "${secretsExample}" > secret-fixtures.yaml

    # Local .sops.yaml creation rules are irrelevant here: the recipients are
    # passed explicitly and the build directory carries no sops config.
    sops encrypt --in-place --age "$pub" secret-fixtures.yaml
    install -m 400 secret-fixtures.yaml "$out/secrets.yaml"
  ''
