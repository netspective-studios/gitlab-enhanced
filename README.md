# GitLab Enhancement Database

This library uses [PgDCP SQLa](https://github.com/netspective-studios/PgDCP) to create an *enhnanced* GitLab schema which includes utility views and repositories cache.

## Dependencies

* `Just`
* `Deno`
* `Perl`
* PostgreSQL client
* `datadash` (for testing generated CSVs)

To check if your dependencies are properly installed, run:

```bash
just doctor
```

## One-time Setup

Copy `.env.example` to `.env` and fill out GitLab production database information. The `.env` file is included in `.gitignore` and will not be git-tracked.

## Creating SQL objects

To drop the enhanced schema and recreate basic SQL objects:

```bash
just context=production db-deploy-clean
```

To idempotently create basic SQL objects without dropping the enhanced schema:

```bash
just context=production db-deploy
```

What's available after `db-deploy` in database point to by `.env`:

* `gitlab_qualified_namespaces` view delivers Gitlab `namespaces` with level and hierarchical qualifications (e.g. path/path/... and Name::Name::...) instead of flat only
* `gitlab_qualified_projects` view delivers GitLab projects with namespace-qualified names and logical paths with hierarchy
* `gitlab_qualified_project_repos` view delivers GitLab projects with namespace-qualified names, logical paths, and physical Gitaly repository paths with hierarchy
* `gitlab_qualified_project_repos_clone(gitlab_host_name)` function delivers GitLab projects with namespace-qualified names, logical paths, and relative Gitaly repository paths on disk plus cloning paths on a given host
* `gitlab_qualified_project_repos_clone(gitlab_host_name, parent_namespace_id)` function delivers GitLab projects under a specific namespace ID with namespace-qualified names, logical paths, and relative Gitaly repository paths on disk plus cloning paths on a given host
* `gitlab_qualified_project_repos_bare(gitlab_bare_repos_home_on_disk)` function delivers GitLab projects with namespace-qualified names, logical paths, and absolute paths to Gitaly bare Git repositories
* `gitlab_qualified_project_repos_bare(gitlab_bare_repos_home_on_disk, parent_namespace_id)` function delivers GitLab projects under a specific namespace ID with namespace-qualified names, logical paths, and absolute paths to Gitaly bare Git repositories

## Discovering and persisting Gitaly Git bare repository content in PostgreSQL

The `just db-deploy` target deploys convenience PostgreSQL views which can then be used by these two `just` targets:

* `discover-gitlab-project-repo-assets`
* `persist-gitlab-project-repo-assets`

### How to use mirror bare repo content into database

```bash
just discover-gitlab-project-repo-assets 8 
just validate-gitlab-project-repo-assets-csv
just persist-gitlab-project-repo-assets
```

* `just discover-project-repo-trees 8` uses PostgreSQL convenience views to generate a CSV file (`gitlab-project-repo-assets.csv`) of all the Gitaly bare Git repositories under GitLab Namespace ID '8' (any GitLab group ID may be passed in).
  * The generated CSV file contains the latest commit information and content for each branch of each GitLab project repo.
  * On a 6-core i5 processor with direct access to the GitLab bare Git repos this take around 2.5 minutes for about 3,500 small project repos (assuming about 37,000 cumulative files included in the 3,500 or so Git repos).
* `just validate-gitlab-project-repo-assets-csv` uses GNU `datamash` to validate `gitlab-project-repo-assets.csv`. This command is optional but it will always be run when using `just persist-gitlab-project-repo-assets` (the PostgreSQL import will not be started if the CSV is not valid).
* `just persist-gitlab-project-repo-assets` validates `gitlab-project-repo-assets.csv` using GNU `datamash` and then inserts all rows in `gitlab-project-repo-assets.csv` into the `gitlab_project_repo_assets` PostgreSQL table using the `COPY FROM` SQL command. This should take less than 30 seconds to complete if the database is on the same server as the CSV file.

#### What `discover-gitlab-project-repo-assets` does

`discover-gitlab-project-repo-assets` uses the `gitlab_qualified_project_repos_bare(gitlab_bare_repos_home_on_disk, parent_namespace_id)` function to find all Gitaly bare Git repositories under a specific GitLab namespace ID (group). Once it finds the bare repos, it uses `xargs` to run Git commands in parallel (using `numproc` processes) to create a CSV file with the following:

| Column                    | Type        | Purpose                                                                                                                                                                             |
| ------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `index`                   | integer     | abitrary row number or row index for informational purposes                                                                                                                         |
| `gl_project_id`           | integer     | GitLab project ID acquired from [GitLab].projects.id table                                                                                                                          |
| `gl_project_repo_id`      | integer     | GitLab project repo ID acquired from [GitLab].project_repositories.id table                                                                                                         |
| `git_branch`              | text        | Git branch acquired from bare Git repo using git for-each-ref command                                                                                                               |
| `git_file_mode`           | text        | Git file mode acquired from bare Git repo using git ls-tree -r {branch} command                                                                                                     |
| `git_asset_type`          | text        | Git asset type (e.g. blob) acquired from bare Git repo using git ls-tree -r {branch} command                                                                                        |
| `git_object_id`           | text        | Git object (e.g. blob) ID acquired from bare Git repo using git ls-tree -r {branch} command                                                                                         |
| `git_file_size_bytes`     | integer     | Git file size in bytes acquired from bare Git repo using git ls-tree -r {branch} command                                                                                            |
| `git_file_name`           | text        | Git file name acquired from bare Git repo using git ls-tree -r {branch} command                                                                                                     |
| `git_commit_hash`         | text        | Git file commit hash acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                                  |
| `git_author_date`         | timestamptz | Git file author date acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                                  |
| `git_commit_date`         | timestamptz | Git file commit date acquired from bare Git repo using git log -1 {branch} {git_file_name} command (commit date is usually the same as author date unless the repo was manipulated) |
| `git_author_name`         | text        | Git file author name acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                                  |
| `git_author_email`        | text        | Git file author e-mail address acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                        |
| `git_committer_name`      | text        | Git file committer name acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                               |
| `git_committer_email`     | text        | Git file committer e-mail address acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                     |
| `git_commit_subject`      | text        | Git file commit message subject acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                       |
| `git_file_content_base64` | text        | Git file commit content, in Base64 format, from bare Git repo using git log -1 {branch} {git_file_name} command                                                                     |

#### What `persist-gitlab-project-repo-assets` does

`persist-gitlab-project-repo-assets` uses the CSV file created by `discover-project-repo-trees` target and:
*  drops the `gitlab_project_repo_assets` table
*  creates the `gitlab_project_repo_assets` table
*  imports the CSV file into the `gitlab_project_repo_assets` table