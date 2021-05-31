# GitLab Enhancement Database

This library uses [PgDCP SQLa](https://github.com/netspective-studios/PgDCP) to create an *enhnanced* GitLab schema which includes utility views and repositories cache.

## Dependencies

* `Just`
* `Deno`
* `Perl`
* PostgreSQL client
* `miller` (for testing generated CSVs)

To check if your dependencies are properly installed, run:

```bash
just doctor
```

## One-time Setup

```bash
git clone https://github.com/netspective-studios/gitlab-enhanced.git 
cd gitlab-enhanced
```

Then:

* Copy `gitlab-canonical.env.example` to `gitlab-canonical.env` and fill out GitLab database information. The `gitlab-canonical.env` file is included in `.gitignore` and will not be git-tracked. All environment variables in `gitlab-canonical.env` will be available, automatically, to the `just` `discover-gitlab-project-repo-assets` target. These two environment variables are important and **they should not share the same value** -- the `just context=production db-deploy-clean` target will destroy any existing `$SQLACTL_GITLAB_ENHANCE_SCHEMA_NAME` schema so be sure to separate the schemas as shown by default otherwise you *could accidentally delete your production GitLab database*.
  * `SQLACTL_GITLAB_CANONICAL_SCHEMA_NAME=public`
  * `SQLACTL_GITLAB_ENHANCE_SCHEMA_NAME=stateless_enhance_service_gitlab`
* Copy `gitlab-project-repo-assets.env.example` to `gitlab-project-repo-assets.env` and fill out database information for the destination of the `gitlab_project_repo_assets` table. The `gitlab-project-repo-assets.env` file is included in `.gitignore` and will not be git-tracked. All environment variables in `gitlab-project-repo-assets.env` will be available, automatically, to the `just` `persist-gitlab-project-repo-assets` target below.

If the `gitlab_project_repo_assets` table will be in the same database/schemas defined by `gitlab-canonical.env` then `gitlab-project-repo-assets.env` could just have the same database credentials. However, if the `gitlab_project_repo_assets` table will be in a different database then the contents of `gitlab-canonical.env` then `gitlab-project-repo-assets.env` should point to their respective databases.

## Creating SQL objects

To drop the enhanced schema and recreate basic SQL objects:

```bash
just context=production db-deploy-clean
```

To idempotently create basic SQL objects without dropping the enhanced schema:

```bash
just context=production db-deploy
```

What's available after `db-deploy` in database pointed to by `.env`:

* `gitlab_qualified_namespaces` view delivers Gitlab `namespaces` with level and hierarchical qualifications (e.g. path/path/... and Name::Name::...) instead of flat only
* `gitlab_qualified_projects` view delivers GitLab projects with namespace-qualified names and logical paths with hierarchy
* `gitlab_qualified_project_repos` view delivers GitLab projects with namespace-qualified names, logical paths, and physical Gitaly repository paths with hierarchy
* `gitlab_qualified_project_repos_clone(gitlab_host_name)` function delivers GitLab projects with namespace-qualified names, logical paths, and relative Gitaly repository paths on disk plus cloning paths on a given host
* `gitlab_qualified_project_repos_clone(gitlab_host_name, parent_namespace_id)` function delivers GitLab projects under a specific namespace ID with namespace-qualified names, logical paths, and relative Gitaly repository paths on disk plus cloning paths on a given host
* `gitlab_qualified_project_repos_bare(gitlab_bare_repos_home_on_disk)` function delivers GitLab projects with namespace-qualified names, logical paths, and absolute paths to Gitaly bare Git repositories
* `gitlab_qualified_project_repos_bare(gitlab_bare_repos_home_on_disk, parent_namespace_id)` function delivers GitLab projects under a specific namespace ID with namespace-qualified names, logical paths, and absolute paths to Gitaly bare Git repositories

## Discovering and persisting Gitaly Git bare repository content in PostgreSQL

The `just db-deploy` target deploys convenience PostgreSQL views which can then be used by these four `just` targets:

* `discover-gitlab-project-repo-assets`
* `persist-gitlab-project-repo-assets`
* `discover-gitlab-project-repo-assets-content`
* `persist-gitlab-project-repo-assets-content`

There is a convenience target that will run all the above in sequence:

* `discover-persist-gitlab-project-repo-assets-content`

### How to mirror bare repo content into database

```bash
just discover-persist-gitlab-project-repo-assets-content 8
```

The above command will run all the following targets in sequence:

```bash
just discover-gitlab-project-repo-assets 8 
just persist-gitlab-project-repo-assets
just discover-gitlab-project-repo-assets-content
just persist-gitlab-project-repo-assets-content
```

* `just discover-gitlab-project-repo-assets 8` uses PostgreSQL convenience views to generate a CSV file (`gitlab-project-repo-assets.csv`) of all the Gitaly bare Git repositories under GitLab Namespace ID '8' (any GitLab group ID may be passed in).
  * The generated CSV file contains the latest commit information (only meta-data, not content) for each branch of each GitLab project repo.
  * On a 6-core i5 processor with direct access to the GitLab bare Git repos this take around 90 seconds for about 3,500 small project repos (assuming about 37,000 cumulative files included in the 3,500 or so Git repos).
* `just persist-gitlab-project-repo-assets` validates `gitlab-project-repo-assets.csv` using `miller` and then inserts all rows in `gitlab-project-repo-assets.csv` into the `gitlab_project_repo_assets` PostgreSQL table using the `COPY FROM` SQL command. This should take less than 30 seconds to complete if the database is on the same server as the CSV file.
* `just discover-gitlab-project-repo-assets-content` uses rows in the `gitlab_project_repo_assets` PostgreSQL table to generate a CSV file (`gitlab-project-repo-assets-content.csv`) which contains the name, size, and base64-encoded content of each unique Git object in all the files discovered through `just discover-gitlab-project-repo-assets 8`. 
  * The generated CSV file contains the Git Object ID, file name, file size in bytes, and base64-encoded content for each unique Git object (uniqueness is determined by Git object ID, git file name, and git file size).
  * On a 6-core i5 processor with direct access to the GitLab bare Git repos this take around 45 seconds for about 9,000 small-ish files.
* `just persist-gitlab-project-repo-assets-content` validates `gitlab-project-repo-assets-content.csv` using `miller` and then inserts all rows in `gitlab-project-repo-assets-content.csv` into the `gitlab_project_repo_assets_content` PostgreSQL table using the `COPY FROM` SQL command. This should take less than 10 seconds to complete if the database is on the same server as the CSV file.

#### What `discover-gitlab-project-repo-assets` does

`discover-gitlab-project-repo-assets` uses the `gitlab_qualified_project_repos_bare(gitlab_bare_repos_home_on_disk, parent_namespace_id)` function to find all Gitaly bare Git repositories under a specific GitLab namespace ID (group). Once it finds the bare repos, it uses `xargs` to run Git commands in parallel (using `numproc` processes) to create a CSV file with the following:

| Column                             | Type        | Purpose                                                                                                                                                                             |
| ---------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `discovered_at`                    | timestamptz | Timestamp of when the discovery of this row occurred                                                                                                                                |
| `gl_project_id`                    | integer     | GitLab project ID acquired from [GitLab].projects.id table                                                                                                                          |
| `gl_project_repo_id`               | integer     | GitLab project repo ID acquired from [GitLab].project_repositories.id table                                                                                                         |
| `gl_gitaly_bare_repo_host`         | text        | GitLab project Gitaly bare repo path host                                                                                                                                           |
| `gl_gitaly_bare_repo_host_ip_addr` | text        | GitLab project Gitaly bare repo path host                                                                                                                                           |
| `gl_gitaly_bare_repo_path`         | text        | GitLab project Gitaly bare repo path                                                                                                                                                |
| `git_branch`                       | text        | Git branch acquired from bare Git repo using git for-each-ref command                                                                                                               |
| `git_file_mode`                    | text        | Git file mode acquired from bare Git repo using git ls-tree -r {branch} command                                                                                                     |
| `git_asset_type`                   | text        | Git asset type (e.g. blob) acquired from bare Git repo using git ls-tree -r {branch} command                                                                                        |
| `git_object_id`                    | text        | Git object (e.g. blob) ID acquired from bare Git repo using git ls-tree -r {branch} command                                                                                         |
| `git_file_size_bytes`              | integer     | Git file size in bytes acquired from bare Git repo using git ls-tree -r {branch} command                                                                                            |
| `git_file_name`                    | text        | Git file name acquired from bare Git repo using git ls-tree -r {branch} command                                                                                                     |
| `git_commit_hash`                  | text        | Git file commit hash acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                                  |
| `git_author_date`                  | timestamptz | Git file author date acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                                  |
| `git_commit_date`                  | timestamptz | Git file commit date acquired from bare Git repo using git log -1 {branch} {git_file_name} command (commit date is usually the same as author date unless the repo was manipulated) |
| `git_author_name`                  | text        | Git file author name acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                                  |
| `git_author_email`                 | text        | Git file author e-mail address acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                        |
| `git_committer_name`               | text        | Git file committer name acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                               |
| `git_committer_email`              | text        | Git file committer e-mail address acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                     |
| `git_commit_subject`               | text        | Git file commit message subject acquired from bare Git repo using git log -1 {branch} {git_file_name} command                                                                       |  |  |

#### What `persist-gitlab-project-repo-assets` does

`persist-gitlab-project-repo-assets` uses the CSV file created by `discover-gitlab-project-repo-assets` target and:
*  drops the `gitlab_project_repo_assets` table
*  creates the `gitlab_project_repo_assets` table
*  imports the CSV file into the `gitlab_project_repo_assets` table

Since the repo trees are now just SQL, every file's meta data and latest commit status is a query away:

```sql
select *
  from stateless_enhance_service_gitlab.gitlab_project_repo_assets
 where git_file_name = 'offering-profile.lhc-form.json'
   and git_branch = 'draft'
```

#### What `discover-gitlab-project-repo-assets-content` does

* `just discover-gitlab-project-repo-assets-content` uses rows in the `gitlab_project_repo_assets` PostgreSQL table to generate a CSV file (`gitlab-project-repo-assets-content.csv`) which contains the name, size, and base64-encoded content of each unique Git object in all the files discovered through `just discover-gitlab-project-repo-assets`. 
* Git objects IDs are considered "globally unique" so we can have the same file content used across Git repos stored only once. 
* There might be some long-term issues with content conflicts that should be considered. Read [SHA\-1 collision detection on GitHub\.com](https://github.blog/2017-03-20-sha-1-collision-detection-on-github-com/) and [10\.2 Git Internals \- Git Objects](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects).

| Column                    | Type        | Purpose                                                                                         |
| ------------------------- | ----------- | ----------------------------------------------------------------------------------------------- |
| `discovered_at`           | timestamptz | Timestamp of when the discovery of this row occurred                                            |
| `git_object_id`           | text        | Git object (e.g. blob) ID acquired from bare Git repo                                           |
| `git_file_name`           | text        | Git file name acquired from bare Git repo                                                       |
| `git_file_size_bytes`     | integer     | Git file size in bytes acquired from bare Git repo                                              |
| `git_file_content_base64` | text        | Git file commit content, in Base64 format, from bare Git repo using git show -r {git_object_id} |

#### What `persist-gitlab-project-repo-assets-content` does

* `just persist-gitlab-project-repo-assets-content` validates `gitlab-project-repo-assets-content.csv` using `miller` and then inserts all rows in `gitlab-project-repo-assets-content.csv` into the `gitlab_project_repo_assets_content` PostgreSQL table using the `COPY FROM` SQL command. 

`persist-gitlab-project-repo-assets-content` uses the CSV file created by `discover-gitlab-project-repo-assets-content` target and:
*  drops the `gitlab_project_repo_assets_content` table
*  creates the `gitlab_project_repo_assets_content` table
*  imports the CSV file into the `gitlab_project_repo_assets_content` table

Since the repo contents are now just SQL, the content and meta data are now a query away:

```sql
select gl_project_id, 
       git_author_date, 
       prac.git_file_size_bytes,
       convert_from(decode(git_file_content_base64, 'base64'), 'UTF8')::jsonb as lhc_form       
  from stateless_enhance_service_gitlab.gitlab_project_repo_assets pra,
       stateless_enhance_service_gitlab.gitlab_project_repo_assets_content prac
 where prac.git_file_name = 'offering-profile.lhc-form.json'
   and git_branch = 'draft'
   and pra.git_object_id = prac.git_object_id
```
