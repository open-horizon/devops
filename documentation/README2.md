# The Step-by-step Procedure To Build A Job Using Jenkins Job Builder With LF-Edge Jenkins
In this demonstration, we create a pipeline job to implement e2e-dev-test for `anax` repo.
1. Fork the `https://github.com/lf-edge/ci-management` repo.
2. Add a separate directory in `jjb/` that will host the configuration files for your project (for example, `jjb/anax/`).
3. Add your job configuration files to the new created directory. For this demonstration, we create the following yaml file (please see `https://github.com/lf-edge/ci-management/jjb/anax/anax.yml`). As shown in `anax.yml`, the job is triggered by a PR submission.
4. Create and submit a PR to merge your `anax/anax.yml` into `lf-edge/ci-management`. If accepted, your job would appear in LF-Edge Jenkins UI, but it would not build until a PR is submitted for `anax` repo.
5. Fork the repo that hosts the source code for the project that you want to build (`open-horizon/anax` for this demonstration).
6. Add the `Jenkinsfile` (and any other files) that implements the e2e-dev-test pipline to the repo.
7. Now, if a PR is created to contribute your changes to `open-horizon/anax`, this would trigger a job build in LF-Edge Jenkins.
