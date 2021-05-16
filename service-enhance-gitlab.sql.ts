import { dcp } from "./deps.ts";

export function initSQL(
  ctx: dcp.DcpInterpolationContext,
  options: dcp.InterpolationContextStateOptions & {
    readonly gitLabCanonicalSchema: dcp.PostgreSqlSchema;
  },
): dcp.DcpInterpolationResult {
  const state = ctx.prepareState(
    ctx.prepareTsModuleExecution(import.meta.url),
    options,
  );
  const [sqr] = state.observableQR(state.schema);
  const [glcsqr] = state.observableQR(options.gitLabCanonicalSchema);

  // our typical naming is to have tables be singular, not plural but we're
  // following GitLab conventions (theirs is plural)
  const glQNView = sqr("gitlab_qualified_namespaces");
  const glQPView = sqr("gitlab_qualified_projects");
  const glQPRView = sqr("gitlab_qualified_project_repos");
  const glQPRCloneFn = sqr("gitlab_qualified_project_repos_clone");
  const glQPRBareFn = sqr("gitlab_qualified_project_repos_bare");
  const glQPRStateTable = sqr(
    "gitlab_qualified_project_repos_state",
  );
  const glPrepQPRStateProc = sqr(
    "gitlab_prepare_qualified_project_repos_state",
  );
  const glNamespacesTable = glcsqr("namespaces");

  // deno-fmt-ignore
  return dcp.SQL(ctx, state)`
      create or replace view ${glQNView} as
        select namespace.*, 
                qualified.level,
                qualified.abs_path as qualified_path,
                qualified.qualified_name 
          from ${glNamespacesTable} namespace
          cross join lateral(
            with recursive recursive_ns (id, level, path_component, abs_path, name_component, qualified_name) as (
                select  id, 0, path, path::text, name, name::text
                from    ${glNamespacesTable}
                where   parent_id is null
                union all
                select  childns.id, t0.level + 1, childns.path, (t0.abs_path || '/' || childns.path)::text, childns.name, (t0.qualified_name || '::' || childns.name)::text
                from    ${glNamespacesTable} childns
                inner join recursive_ns t0 on t0.id = childns.parent_id)
            select  level, abs_path::text, qualified_name::text
            from    recursive_ns
            where   id = namespace.id
          ) as qualified(level, abs_path, qualified_name);
      comment on view ${glQNView} is 'All Gitlab namespaces with level and hierarchical qualifications';
  
      create or replace view ${glQPView} as
        select namespace.level as namespace_level,
                namespace.qualified_name as qualified_namespace_name,
                namespace.qualified_name as qualified_namespace_path,
                namespace.level+1 as project_level,
                project.*,
                namespace.qualified_path || '/' || project.path as qualified_project_path,
                namespace.qualified_name || '::' || project.name as qualified_project_name
          from ${glcsqr("projects")} project
          left join ${glQNView} namespace on project.namespace_id = namespace.id;
      comment on view ${glQPView} is 'All registered GitLab projects with namespace-qualified names and logical paths';
  
      create or replace view ${glQPRView} as
        select qp.*,
               pr.id as project_repo_id, 
               pr.shard_id as project_repo_gitaly_shard_id, 
               pr.disk_path as project_repo_gitaly_disk_path,
               qp.qualified_project_path || '.git' as qualified_project_git_dir_path,
               pr.disk_path || '.git' as project_repo_gitaly_disk_git_dir_rel_path
          from ${glQPView} qp
        left join ${glcsqr("project_repositories")} pr on pr.project_id = qp.id;
      comment on view ${glQPRView} is 'All registered GitLab projects with namespace-qualified names, logical paths, and physical Gitaly repository paths';
  
      CREATE OR REPLACE FUNCTION ${glQPRCloneFn}(gitlab_host_name text) RETURNS table(qpr ${glQPRView}, clone_ssh text, clone_https text) AS $func$
      BEGIN
        RETURN QUERY 
          select repos as qpr,
                 format('git@%s:%s', gitlab_host_name, repos.qualified_project_git_dir_path) as clone_ssh,
                 format('https://%s/%s', gitlab_host_name, repos.qualified_project_git_dir_path) as clone_https
            from ${glQPRView} as repos;
      END
      $func$ LANGUAGE plpgsql;
  
      CREATE OR REPLACE FUNCTION ${glQPRCloneFn}(gitlab_host_name text, parent_namespace_id integer) RETURNS table(qpr ${glQPRView}, clone_ssh text, clone_https text) AS $func$
      BEGIN
        RETURN QUERY 
          select repos as qpr,
                 format('git@%s:%s', gitlab_host_name, repos.qualified_project_git_dir_path) as clone_ssh,
                 format('https://%s/%s', gitlab_host_name, repos.qualified_project_git_dir_path) as clone_https
            from ${glQPRView} as repos
           where namespace_id in (
               with recursive descendants AS (
                  select parent_namespace_id AS id 
                  union all 
                  select ns.id 
                  from ${glNamespacesTable} as ns 
                  join descendants on descendants.id = ns.parent_id)
              select id from descendants);
      END
      $func$ LANGUAGE plpgsql;
  
      CREATE OR REPLACE FUNCTION ${glQPRBareFn}(gitlab_bare_repos_home_on_disk text) RETURNS table(qpr ${glQPRView}, git_dir_abs_path text) AS $func$
      BEGIN
        RETURN QUERY 
          select repos as qpr,
                 format('%s/%s', gitlab_bare_repos_home_on_disk, repos.project_repo_gitaly_disk_git_dir_rel_path) as git_dir_abs_path
            from ${glQPRView} as repos;
      END
      $func$ LANGUAGE plpgsql;
  
      CREATE OR REPLACE FUNCTION ${glQPRBareFn}(gitlab_bare_repos_home_on_disk text, parent_namespace_id integer) RETURNS table(qpr ${glQPRView}, git_dir_abs_path text) AS $func$
      BEGIN
        RETURN QUERY 
          select repos as qpr,
                 format('%s/%s', gitlab_bare_repos_home_on_disk, repos.project_repo_gitaly_disk_git_dir_rel_path) as git_dir_abs_path
            from ${glQPRView} as repos
           where namespace_id in (
               with recursive descendants AS (
                  select parent_namespace_id AS id 
                  union all 
                  select ns.id 
                  from ${glNamespacesTable} as ns 
                  join descendants on descendants.id = ns.parent_id)
              select id from descendants);
      END
      $func$ LANGUAGE plpgsql;
   
      -- qualified references observed in this template:
      -- ${state.qualifiedReferencesObserved.referencesObserved.map(r => `* ${r}`).join(`\n    -- `)}
  `;
}
