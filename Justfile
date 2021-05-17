gitLabReposHome := "/var/lib/docker/volumes/gl-infra-experimental-medigy-com_data/_data/git-data/repositories"
gitLabCanonicalConfigEnvFile := "gitlab-canonical.env"
gitlabProjectRepoAssetsStorageEnvFile := "gitlab-project-repo-assets.env"

# None of the `psql` commands below have any credentials supplied because the .env
# file is supposed to supply them (.env is read by `just` and converted to env vars).
psqlCmd := "psql -P pager=off -qtAX"

# Expected to be provided in the CLI
context := "unknown"

# Inspect SQLa execution environment
inspect: _validate-env
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Context: {{context}}"
    echo "psql: {{psqlCmd}} (will use PG* env variables from *.env for credentials)"
    set -o allexport && source {{gitLabCanonicalConfigEnvFile}} && set +o allexport
    echo "GitLab schema: $SQLACTL_GITLAB_CANONICAL_SCHEMA_NAME (from {{gitlabProjectRepoAssetsStorageEnvFile}})"
    echo "GitLab Enhanced schema: $SQLACTL_GITLAB_ENHANCE_SCHEMA_NAME (from {{gitLabCanonicalConfigEnvFile}})"
    set -o allexport && source {{gitlabProjectRepoAssetsStorageEnvFile}} && set +o allexport
    echo "Project Repo Assets schema: $SQLACTL_GITLAB_PROJECT_REPO_ASSETS_SCHEMA_NAME (from {{gitlabProjectRepoAssetsStorageEnvFile}})"

# Drop $SQLACTL_GITLAB_ENHANCE_SCHEMA_NAME schema, interpolate and generate SQL then load it into database $SQLACTL_GITLAB_ENHANCE_SCHEMA_NAME schema supplied by .env
db-deploy-clean: _validate-context _validate-env
    #!/usr/bin/env bash
    set -euo pipefail
    set -o allexport && source {{gitLabCanonicalConfigEnvFile}} && set +o allexport
    {{psqlCmd}} -c "drop schema if exists $SQLACTL_GITLAB_ENHANCE_SCHEMA_NAME cascade";
    just context={{context}} db-deploy

# Interpolate and generate SQL then load it into database $SQLACTL_GITLAB_ENHANCE_SCHEMA_NAME schema supplied by .env
db-deploy: _validate-context _validate-env
    #!/usr/bin/env bash
    set -euo pipefail
    set -o allexport && source {{gitLabCanonicalConfigEnvFile}} && set +o allexport
    deno run -A --unstable sqlactl.ts interpolate --context={{context}} --verbose --git-status | {{psqlCmd}}

# Interpolate and generate SQL to STDOUT
interpolate-sql: _validate-context
    #!/usr/bin/env bash
    set -euo pipefail
    set -o allexport && source {{gitLabCanonicalConfigEnvFile}} && set +o allexport
    deno run -A --unstable sqlactl.ts interpolate --context={{context}} --verbose --git-status

discover-gitlab-project-repo-assets gitLabGroup options="extended-attrs,content" destFileName="gitlab-project-repo-assets.csv": _validate-env _validate-repos-home
    #!/usr/bin/env bash
    set -euo pipefail
    set -o allexport && source {{gitLabCanonicalConfigEnvFile}} && set +o allexport
    rm -f '{{destFileName}}'
    perl gitlab-project-repos-transform.pl csv-header '{{options}}' '{{destFileName}}'
    {{psqlCmd}} -AF ' ' <<REPOS_SQL | xargs -P`nproc` -n6 perl gitlab-project-repos-transform.pl
        select row_number() OVER () as row_num, '{{options}},is-parallel-op' as options, '{{destFileName}}' as output_dest, 
               (qpr).id, (qpr).project_repo_id, git_dir_abs_path
          from $SQLACTL_GITLAB_ENHANCE_SCHEMA_NAME.gitlab_qualified_project_repos_bare('{{gitLabReposHome}}', {{gitLabGroup}})
    REPOS_SQL

validate-gitlab-project-repo-assets-csv fileName="gitlab-project-repo-assets.csv":
    #!/usr/bin/env bash
    set -euo pipefail
    datamash check --header-in --field-separator=, < "{{fileName}}" || exit -1

persist-gitlab-project-repo-assets tableName='gitlab_project_repo_assets' options="extended-attrs,content" repoTreesFileName="gitlab-project-repo-assets.csv": _validate-env validate-gitlab-project-repo-assets-csv
    #!/usr/bin/env bash
    set -euo pipefail
    set -o allexport && source {{gitlabProjectRepoAssetsStorageEnvFile}} && set +o allexport
    {{psqlCmd}} <<CREATE_TABLE_SQL
        DROP TABLE IF EXISTS $SQLACTL_GITLAB_PROJECT_REPO_ASSETS_SCHEMA_NAME.{{tableName}};
        CREATE TABLE $SQLACTL_GITLAB_PROJECT_REPO_ASSETS_SCHEMA_NAME.{{tableName}}(
            `perl gitlab-project-repos-transform.pl create-table-clauses '{{options}}'`
        );        
    CREATE_TABLE_SQL
    cat "{{repoTreesFileName}}" | {{psqlCmd}} -c "COPY $SQLACTL_GITLAB_PROJECT_REPO_ASSETS_SCHEMA_NAME.{{tableName}} FROM STDIN CSV HEADER"
    echo "Inserted `{{psqlCmd}} -c "select count(*) from $SQLACTL_GITLAB_PROJECT_REPO_ASSETS_SCHEMA_NAME.{{tableName}}"` rows into $SQLACTL_GITLAB_PROJECT_REPO_ASSETS_SCHEMA_NAME.{{tableName}}"

# Show all dependencies
doctor:
    #!/usr/bin/env bash
    set -euo pipefail
    just --version
    deno --version
    psql -V
    perl --version | sed -n '2p'
    datamash --version | sed -n '1p'
    echo "{{gitLabReposHome}} is `sudo test -d {{gitLabReposHome}}/@hashed && echo 'valid for sudoers' || echo 'does not exist'`"

_validate-context-value-equals value:
    #!/usr/bin/env bash
    case "{{context}}" in
        {{value}}) ;;
        *)
            echo "***************************************************************************************"
            echo "** This command can only be run when 'context' is set to '{{value}}'"
            echo "***************************************************************************************"
            exit 1;;
    esac

_validate-context:
    #!/usr/bin/env bash
    case "{{context}}" in
        sandbox) ;;
        devl) ;;
        test) ;;
        staging) ;;
        production) ;;
        *)
            echo "***************************************************************************************"
            echo "** Proper 'context' argument must be passed to Justfile.                              *"
            echo "** Add context=sandbox (or devl | test | staging | production) before Justfile target *"
            echo "***************************************************************************************"
            exit 1;;
    esac

_validate-env:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ ! -f {{gitLabCanonicalConfigEnvFile}} ]]; then
        echo "{{gitLabCanonicalConfigEnvFile}} does not exist, run 'cp {{gitLabCanonicalConfigEnvFile}}.example {{gitLabCanonicalConfigEnvFile}}' and add credentials"
        exit 1
    fi
    if [[ ! -f {{gitlabProjectRepoAssetsStorageEnvFile}} ]]; then
        echo "{{gitLabCanonicalConfigEnvFile}} does not exist, run 'cp {{gitlabProjectRepoAssetsStorageEnvFile}}.example {{gitlabProjectRepoAssetsStorageEnvFile}}' and add credentials"
        exit 1
    fi

# Make sure the Gitaly repositories are accessible
_validate-repos-home:
    #!/usr/bin/env bash
    if sudo test -d {{gitLabReposHome}}/@hashed; then
        echo "Using GitLab Gitaly Repos Home: {{gitLabReposHome}}"
    else
        echo "{{gitLabReposHome}}/@hashed does not exist"
        exit 1
    fi
