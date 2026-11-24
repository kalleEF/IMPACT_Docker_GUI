# Expected values of the docker_setup tests

| File | Content | Source |
|------|---------|--------|
| `github_known_hosts` | GitHub's three public SSH host keys, one line each | GitHub's documentation, "GitHub's SSH key fingerprints", read on 23 November 2026 |
| `github_fingerprints` | The SHA256 fingerprints of the same keys | The same page |
| `local-start.txt` | Owner, group and access mode of the files the image writes in a LOCAL start | See the head of the file |

The tests compare what the image writes with these files. The key lines are a second copy,
kept apart from `docker_setup/git-identity.sh` on purpose: a slip in one of the two shows as
a failing test.

When GitHub replaces a host key, update `git-identity.sh`, `github_known_hosts` and
`github_fingerprints` together from
<https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>.
