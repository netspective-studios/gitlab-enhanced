import { dcpCLI, dcpT, dotenv, path } from "./deps.ts";
import * as gitLabEnhance from "./service-enhance-gitlab.sql.ts";

export class Controller extends dcpCLI.Controller {
  async interpolate(
    interpOptions: dcpT.PostgreSqlInterpolationPersistOptions,
  ): Promise<void> {
    const gitLabCanonicalSchema = new dcpT.schemas.TypicalSchema(
      Deno.env.get("SQLACTL_GITLAB_CANONICAL_SCHEMA_NAME")!,
    );
    const glEnhanceSchema = new dcpT.schemas.TypicalSchema(
      Deno.env.get("SQLACTL_GITLAB_ENHANCE_SCHEMA_NAME")!,
    );
    const ic = dcpT.typicalDcpInterpolationContext(
      await this.determineVersion(),
      glEnhanceSchema,
      (p) => {
        const fileRes = "file://";
        return p.source.startsWith(fileRes)
          ? path.relative(
            this.options.projectHome,
            p.source.substr(fileRes.length),
          )
          : p.source;
      },
    );

    const p = new dcpT.PostgreSqlInterpolationPersistence(interpOptions);
    p.registerPersistableResult(
      gitLabEnhance.initSQL(ic, {
        schema: glEnhanceSchema,
        gitLabCanonicalSchema, // assume we're running on the same server as GitLab
      }),
    );
    await p.persistResults();
  }
}

if (import.meta.main) {
  // Read variables either from the environment or .env. `safe` is set to true
  // so that we are sure that all the variables we need are supplied or we error
  // out. `export` is set to true so that the variables are put into Deno.env().
  // Env vars will be available using Deno.env.get("*").
  dotenv.config({ safe: true, export: true });
  const cliEC = dcpCLI.cliArgs({ calledFromMetaURL: import.meta.url });
  await dcpCLI.CLI(new Controller(cliEC, dcpCLI.cliControllerOptions(cliEC)));
}
