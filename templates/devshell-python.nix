# Example Python development shell for projects
# Add to your project's flake.nix outputs
{
  devShells.aarch64-darwin.default = pkgs.mkShell {
    name = "python-dev";
    buildInputs = with pkgs; [
      python311
      python311Packages.pip
      python311Packages.virtualenv
      python311Packages.black
      python311Packages.flake8
      # Add project-specific Python packages here
    ];
    shellHook = ''
      echo "Python 3.11 development environment"
      python --version
    '';
  };
}
