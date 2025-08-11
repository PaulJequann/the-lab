import bcrypt
from typing import Any, Callable
from urllib.parse import urlparse
import makejinja
import subprocess
import yaml
import os


def bcrypt_password(value: str) -> str:
    """Return the bcrypt hash of the given password string."""
    salt = bcrypt.gensalt()
    hashed = bcrypt.hashpw(value.encode('utf-8'), salt)
    return hashed.decode('utf-8')


def build_helm_secrets_path(secret: str, key: str, gh_repo: str, gh_repo_branch: str, app_repo_path: str, secret_file_name: str) -> str:
    """
    Construct the full helm-secrets path for a SOPS secret stored in GitHub.

    Args:
        secret: The name of the Kubernetes secret holding the age key.
        key: The key within the secret (e.g., 'keys.txt').
        gh_repo: The full HTTPS URL of the GitHub repository.
        gh_repo_branch: The branch where the secret file is located.
        app_repo_path: The path from the repo root to the application directory.
        secret_file_name: The name of the SOPS file to decrypt.

    Returns:
        A formatted string for helm-secrets to decrypt a remote SOPS file.
    """
    # Use urllib.parse for robust URL handling.
    parsed_url = urlparse(gh_repo)
    if parsed_url.scheme != 'https' or parsed_url.netloc != 'github.com':
        raise ValueError(
            f"Invalid GitHub repository URL: {gh_repo}. Must be a valid https://github.com URL.")

    # Safely get the user/repo part and remove the optional .git suffix.
    repo_path = parsed_url.path.lstrip('/').removesuffix('.git')

    secret_file_name = secret_file_name.lstrip('/')

    raw_url_base = "https://raw.githubusercontent.com"
    secret_url = f"{raw_url_base}/{repo_path}/refs/heads/{gh_repo_branch}/{app_repo_path}/{secret_file_name}"

    return f"secrets+age-import:///{secret}/{key}?{secret_url}"


def seal_secret(name: str, namespace: str, data: dict[str, str], cert_path: str = ".sealed-secrets-public-cert.pem") -> str:
    """
    Generates a SealedSecret manifest by calling the kubeseal CLI.

    Args:
        name: The name of the Kubernetes Secret.
        namespace: The namespace for the Secret.
        data: A dictionary of key-value pairs for the Secret data.
        cert_path: The path to the Sealed Secrets public certificate.

    Returns:
        A string containing the YAML for the SealedSecret resource.
    """
    if not os.path.exists(cert_path):
        raise FileNotFoundError(
            f"Sealed Secrets certificate not found at '{cert_path}'. "
            "Please run the 'secrets:init' task first."
        )

    # 1. Construct the plaintext Secret manifest in memory
    secret_manifest = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {
            "name": name,
            "namespace": namespace,
        },
        "type": "Opaque",
        "stringData": data,  # Use stringData for automatic base64 encoding by Kubernetes
    }
    secret_yaml_string = yaml.dump(secret_manifest)

    # 2. Prepare and run the kubeseal command
    kubeseal_command = [
        "kubeseal",
        "--format", "yaml",
        "--cert", cert_path,
        # Assuming controller is in kube-system
        "--controller-namespace", "kube-system",
    ]

    try:
        process = subprocess.run(
            kubeseal_command,
            input=secret_yaml_string,
            capture_output=True,
            text=True,
            check=True,  # This will raise an exception if kubeseal fails
        )
        return process.stdout
    except FileNotFoundError:
        raise RuntimeError(
            "The 'kubeseal' command was not found. Is it installed and in your PATH?")
    except subprocess.CalledProcessError as e:
        # Provide more detailed error feedback
        raise RuntimeError(
            f"kubeseal command failed with exit code {e.returncode}:\n"
            f"STDOUT:\n{e.stdout}\n"
            f"STDERR:\n{e.stderr}"
        )


class Plugin(makejinja.plugin.Plugin):
    def __init__(self, data: dict[str, Any], config: makejinja.config.Config):
        # Store config/data if needed for future extension
        self._data = data
        self._config = config

    def filters(self) -> makejinja.plugin.Filters:
        # Only the bcrypt_password filter is registered
        return [bcrypt_password]

    def globals(self) -> list[Callable[..., Any]]:
        # This method registers functions that can be called directly in templates.
        return [build_helm_secrets_path, seal_secret]
