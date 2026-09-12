pipeline {
  agent any

  parameters {
    choice(
      name: 'REFRESH_JENKINSFILE',
      choices: ['NO', 'YES'],
      description: 'YES = reload Jenkinsfile parameter UI and exit (no deployment). Run once after Jenkinsfile changes.'
    )
    extendedChoice(
      name: 'PIPELINE_STAGES',
      type: 'PT_CHECKBOX',
      value: 'VALIDATE,TERRAFORM,PREREQS,PORTAL,IDENTITY,CM_INSTALL,CM_TLS_KRB_LDAP,CDH_INSTALL,MONITORING,ECS_INSTALL',
      defaultValue: 'VALIDATE,TERRAFORM',
      multiSelectDelimiter: ',',
      visibleItemCount: 10,
      quoteValue: false,
      description: 'Stages to run (fixed order). See PIPELINE_STAGES_REFERENCE below for full guide. Legacy CDH_BASE → CM_TLS_KRB_LDAP + CDH_INSTALL. Run REFRESH_JENKINSFILE=YES after Jenkinsfile changes.',
      descriptionPropertyValue: '''VALIDATE: prereq checks (VALIDATION_CHECKS),TERRAFORM: EC2/VPC/SG/EIP + inventory,PREREQS: Ansible 01-09,PORTAL: portal bootstrap (10),IDENTITY: FreeIPA/AD phase 2,CM_INSTALL: CM server phase 3,CM_TLS_KRB_LDAP: TLS/Kerberos/LDAP 27-30,CDH_INSTALL: base cluster (31),MONITORING: Grafana/Prom (32),ECS_INSTALL: ECS cluster (33)'''
    )
    text(
      name: 'PIPELINE_STAGES_REFERENCE',
      defaultValue: '''PIPELINE_STAGES — reference (edit optional; default is documentation)

Run order: VALIDATE → TERRAFORM → PREREQS → PORTAL → IDENTITY → CM_INSTALL → CM_TLS_KRB_LDAP → CDH_INSTALL → MONITORING → ECS_INSTALL

| Checkbox | What runs |
| VALIDATE | validate-prereqs.sh — only VALIDATION_CHECKS you select |
| TERRAFORM | run-terraform.sh — plan/apply; writes inventory.ini + PEM |
| PREREQS | Ansible phase 1 (playbooks 01–09) |
| PORTAL | Deployment portal bootstrap (10); before CM when portal enabled |
| IDENTITY | Ansible phase 2 — FreeIPA or AD |
| CM_INSTALL | Ansible phase 3 — CM repos, Postgres, CM server |
| CM_TLS_KRB_LDAP | Auto-TLS, Kerberos, CMS, LDAP (27–30) |
| CDH_INSTALL | CDH base cluster (31_setup_base_cluster.yml) |
| MONITORING | Monitoring stack (32); needs PORTAL; MONITORING_STACK_ENABLED |
| ECS_INSTALL | ECS (33) + optional data services when ECS_DATA_SERVICES_DEPLOY_ENABLED |

Legacy: CDH_BASE (old jobs) expands to CM_TLS_KRB_LDAP + CDH_INSTALL — check those two boxes instead.

PORTAL auto-run: when DEPLOYMENT_PORTAL_ENABLED=true (default) and you select IDENTITY, CM_INSTALL, CM_TLS_KRB_LDAP, CDH_INSTALL, MONITORING, or ECS without PORTAL, the pipeline inserts PORTAL after PREREQS.

Examples:
  Validate + provision only: VALIDATE,TERRAFORM
  Through CM (greenfield): VALIDATE,TERRAFORM,PREREQS,IDENTITY,CM_INSTALL (+ PORTAL auto if portal enabled)
  Old PREREQS,IDENTITY,CM_INSTALL,CDH_BASE equivalent: PREREQS,IDENTITY,CM_INSTALL,CM_TLS_KRB_LDAP,CDH_INSTALL (+ VALIDATE,TERRAFORM if you still provision VMs; + PORTAL auto when DEPLOYMENT_PORTAL_ENABLED)

Details: jenkins/README.md
''',
      description: 'Read-only stage guide (shown on Build with Parameters). Leave default or copy from here; does not affect the pipeline unless you rely on it for notes.'
    )
    extendedChoice(
      name: 'VALIDATION_CHECKS',
      type: 'PT_CHECKBOX',
      value: 'TOOLS,AWS_CREDS,TFVARS,ANSIBLE_SYNTAX,INVENTORY,EMAIL_FORMAT',
      defaultValue: 'TOOLS,AWS_CREDS,TFVARS,ANSIBLE_SYNTAX,INVENTORY',
      multiSelectDelimiter: ',',
      visibleItemCount: 6,
      quoteValue: false,
      description: '''Used only when PIPELINE_STAGES includes VALIDATE (validate-prereqs.sh + Check Parameters). Example: TOOLS,AWS_CREDS,TFVARS,ANSIBLE_SYNTAX,INVENTORY,EMAIL_FORMAT. Uncheck any box to skip that check.

TOOLS — On Jenkins agent: which git jq aws python3; adds terraform if TERRAFORM stage selected; adds ansible-playbook if any Ansible stage selected or ANSIBLE_SYNTAX checked.

AWS_CREDS — aws_cred_diagnose + aws sts get-caller-identity (CREDENTIALS_USER ~/.aws when USE_CREDENTIALS_USER_AWS=true else instance IAM role).

TFVARS — Resolve TFVARS_FILE; load ENVIRONMENT OWNER AWS_REGION from config; if TERRAFORM also selected runs validate-aws-resources.sh (keypair + security group exist or creatable).

ANSIBLE_SYNTAX — ansible-playbook --syntax-check on each numbered playbook under ansible-playbooks/ (installs local ansible if needed).

INVENTORY — Fail if ansible-playbooks/inventory.ini missing (auto-enabled when you select Ansible stages without TERRAFORM).

EMAIL_FORMAT — In Check Parameters: regex-validate NOTIFICATION_EMAIL when non-empty (in addition to tfvars/email usage).''',
      descriptionPropertyValue: '''TOOLS: verify CLIs on agent; +terraform if TERRAFORM; +ansible-playbook if Ansible stages or ANSIBLE_SYNTAX,AWS_CREDS: aws sts get-caller-identity (holautosa ~/.aws or instance role),TFVARS: tfvars file + ENVIRONMENT/OWNER/REGION; AWS keypair/SG pre-check if TERRAFORM,ANSIBLE_SYNTAX: syntax-check all numbered ansible-playbooks/*.yml,INVENTORY: require ansible-playbooks/inventory.ini on disk,EMAIL_FORMAT: validate NOTIFICATION_EMAIL format in Check Parameters when set'''
    )
    booleanParam(name: 'DRY_RUN', defaultValue: false, description: 'Terraform plan only / Ansible --check --diff (no apply)')
    booleanParam(name: 'USE_CREDENTIALS_USER_AWS', defaultValue: true, description: 'Use CREDENTIALS_USER ~/.aws credentials (default on — uncheck to use EC2 instance IAM role via IMDS)')
    string(name: 'CREDENTIALS_USER', defaultValue: 'holautosa', description: 'OS user whose ~/.aws and ~/.ssh credentials to use (read-only; files not modified)')
    choice(
      name: 'VPC_MODE',
      choices: ['USE_DEFAULT', 'CREATE_NEW'],
      description: '''Terraform VPC (TERRAFORM stage). USE_DEFAULT: create_vpc=false — use account default VPC and its subnets (needs a default VPC in the region). CREATE_NEW: create_vpc=true — new VPC from VPC_NAME/CIDR/AZ/subnet fields below.

Works with any SG_MODE. CREATE_NEW VPC + USE_EXISTING SG only if that SG already exists in that VPC (sg-id or name); greenfield = CREATE_NEW for both.'''
    )
    choice(
      name: 'SG_MODE',
      choices: ['USE_EXISTING', 'CREATE_NEW'],
      description: '''Terraform security group (TERRAFORM stage). USE_EXISTING: create_new_sg=false — attach SG by EXISTING_SG_NAME (sg-id or name in the target VPC; default {ENVIRONMENT}-pvc_cluster_sg); Terraform does not change its rules — edit in AWS. CREATE_NEW: create_new_sg=true — Terraform creates SG in the target VPC; ingress via ALLOW_ALL + ALLOWED_CIDRS (all protocols/ports).

Target VPC = default VPC when VPC_MODE=USE_DEFAULT, or the new VPC when VPC_MODE=CREATE_NEW. Recommended pairs: USE_DEFAULT+USE_EXISTING | USE_DEFAULT+CREATE_NEW | CREATE_NEW+CREATE_NEW.'''
    )
    booleanParam(
      name: 'CREATE_EIP',
      defaultValue: true,
      description: 'TERRAFORM: create_eip=true — allocate Elastic IP and associate with cldr-mngr (independent of VPC_MODE/SG_MODE). Name tag: CLDR_EIP_NAME (empty = {ENVIRONMENT}-cldr-mngr-eip). Uncheck to use instance public IP only.'
    )
    string(name: 'VPC_NAME', defaultValue: '', description: 'CREATE_NEW VPC: name (empty = {ENVIRONMENT}-cldr-vpc)')
    string(name: 'VPC_CIDR_BLOCK', defaultValue: '172.16.0.0/16', description: 'CREATE_NEW VPC: CIDR block')
    string(name: 'VPC_AZS', defaultValue: '["ap-southeast-1a","ap-southeast-1b"]', description: 'CREATE_NEW VPC: JSON AZ list')
    string(name: 'VPC_PUBLIC_SUBNETS_CIDR', defaultValue: '["172.16.0.0/24"]', description: 'CREATE_NEW VPC: JSON public subnet CIDRs')
    string(name: 'VPC_PRIVATE_SUBNETS_CIDR', defaultValue: '[]', description: 'CREATE_NEW VPC: JSON private subnet CIDRs')
    booleanParam(name: 'ENABLE_NAT_GATEWAY', defaultValue: false, description: 'CREATE_NEW VPC: enable NAT gateway')
    booleanParam(name: 'ENABLE_VPN_GATEWAY', defaultValue: false, description: 'CREATE_NEW VPC: enable VPN gateway')
    string(name: 'EXISTING_SG_NAME', defaultValue: '', description: 'USE_EXISTING SG: sg-id or name (empty = {ENVIRONMENT}-pvc_cluster_sg)')
    string(name: 'SG_NAME', defaultValue: '', description: 'CREATE_NEW SG: name (empty = {ENVIRONMENT}-pvc_cluster_sg)')
    booleanParam(
      name: 'ALLOW_ALL',
      defaultValue: false,
      description: '''CREATE_NEW SG only. Ingress is always all protocols and all ports (AWS "All traffic", protocol -1) — this flag chooses WHO can reach the cluster, not which TCP ports.
Unchecked (false, recommended): inbound all traffic from ALLOWED_CIDRS only (office/Jenkins /32s). ALLOWED_CIDRS is ignored for external ingress when checked true.
Checked (true): inbound all traffic from 0.0.0.0/0 (public internet). ALLOWED_PORTS does not narrow ports in either case.'''
    )
    string(
      name: 'ALLOWED_CIDRS',
      defaultValue: '["137.83.231.109/32", "137.83.231.11/32", "208.127.31.110/32", "208.127.31.11/32", "139.180.248.227/32", "54.254.32.236/32"]',
      description: '''CREATE_NEW SG when ALLOW_ALL=false: JSON array of source CIDRs (compact JSON, e.g. ["1.2.3.4/32"]). Each CIDR gets one rule: all protocols/ports inbound (not per-port TCP). Include Jenkins agent egress IP for SSH/Ansible. Ignored for external ingress when ALLOW_ALL=true (world-open). SG_MODE=USE_EXISTING: edit rules in AWS console instead.'''
    )
    string(
      name: 'ALLOWED_PORTS',
      defaultValue: '[22,443,80,7180,7183,7182,8088,5050,8089]',
      description: '''Not applied to Terraform security group rules (ALLOW_ALL true or false). Ingress is always all traffic from ALLOWED_CIDRS or 0.0.0.0/0; changing this list does not open or close individual TCP ports.
Kept for .tfvars.yaml / docs — typical ports: 22 SSH; 80/443 HTTP(S); 7180/7182/7183 CM; 8088 Caddy deployment portal (ops host, usually ipaserver); 5050 pgAdmin; 8089 cAdvisor. CREATE_NEW SG with ALLOW_ALL=false already allows all ports from ALLOWED_CIDRS. USE_EXISTING SG: ensure those ports are open from Jenkins/office CIDRs.'''
    )
    string(
      name: 'CLDR_EIP_NAME',
      defaultValue: '',
      description: '''When CREATE_EIP=true (TERRAFORM): AWS Name tag for the Elastic IP attached to the Cloudera Manager host (cldr-mngr). Empty = {ENVIRONMENT}-cldr-mngr-eip. Does not control security group ports — use ALLOW_ALL + ALLOWED_CIDRS for ingress.'''
    )
    string(name: 'ENVIRONMENT', defaultValue: 'development', description: 'Name prefix + Terraform workspace (overrides tfvars when set)')
    string(name: 'OWNER', defaultValue: 'ksahu-ygulati', description: 'Owner tag — required for Terraform/Ansible if not set in tfvars')
    string(name: 'AWS_REGION', defaultValue: 'ap-southeast-1', description: 'AWS region override (e.g. ap-southeast-1)')
    string(name: 'AMI_ID', defaultValue: 'ami-030a276b398df7eb7', description: 'AMI override for all instance groups in ap-southeast-1 (empty = use tfvars)')
    string(name: 'CLDR_MNGR_COUNT', defaultValue: '1', description: 'CM host count override (positive integer)')
    string(name: 'CLDR_MNGR_INSTANCE_TYPE', defaultValue: 'm5.4xlarge', description: 'CM instance type override (e.g. m5.4xlarge)')
    string(name: 'CLDR_MNGR_VOLUME_SIZE', defaultValue: '300', description: 'CM root volume GB override (positive integer)')
    string(name: 'IPA_SERVER_COUNT', defaultValue: '1', description: 'FreeIPA server count override')
    string(name: 'IPA_SERVER_INSTANCE_TYPE', defaultValue: 'm5.xlarge', description: 'FreeIPA instance type override')
    string(name: 'PVCBASE_MASTER_COUNT', defaultValue: '1', description: 'CDH base master count override')
    string(name: 'PVCBASE_WORKER_COUNT', defaultValue: '3', description: 'CDH base worker count override')
    string(name: 'PVCBASE_WORKER_INSTANCE_TYPE', defaultValue: 'm5.4xlarge', description: 'CDH base worker instance type override')
    string(name: 'PVCECS_MASTER_COUNT', defaultValue: '1', description: 'ECS master count override')
    string(name: 'PVCECS_WORKER_COUNT', defaultValue: '7', description: 'ECS worker count override')
    string(name: 'PVCECS_WORKER_INSTANCE_TYPE', defaultValue: 'r5a.4xlarge', description: 'ECS worker instance type override')
    string(name: 'TFVARS_FILE', defaultValue: '.tfvars.yaml', description: 'Config file path relative to repo root (empty = auto-detect)')
    string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Git branch to checkout (no spaces or ..)')
    string(name: 'NOTIFICATION_EMAIL', defaultValue: '', description: 'Email recipient (defaults to BUILD_USER_EMAIL; validated when set)')
    text(
      name: 'ANSIBLE_GROUP_VARS_YAML',
      defaultValue: '''# Ansible-only overrides (domain, versions, passwords) — see jenkins/ansible-group-vars-allowed-keys.yaml
# Example:
# ipaserver_domain: cldrsetup.local
# cdh_version: "7.3.2.10000"
# ecs_pvc_ds_version: "1.5.5-h3300"
# monitoring_stack_enabled: false   # optional — prefer MONITORING_STACK_ENABLED checkbox above
''',
      description: 'Ansible-only YAML (allowed keys only): domain, stack versions, java/postgres/jdbc/psycopg, passwords. Not full all.yml — see jenkins/ansible-group-vars-allowed-keys.yaml. Monitoring: use MONITORING_STACK_ENABLED checkbox (wins over textarea).'
    )
    string(name: 'CM_REPO_USERNAME', defaultValue: '', description: 'Optional archive.cloudera.com username (empty = all.yml, *info.txt, or skip)')
    password(name: 'CM_REPO_PASSWORD', defaultValue: '', description: 'Optional archive.cloudera.com password (empty = all.yml, *info.txt, or skip)')
    text(
      name: 'CM_LICENSE_CONTENT',
      defaultValue: '',
      description: 'Optional Cloudera license file content (multiline). Used when no *license* file on agent. Empty = trial or existing file on agent.'
    )
    booleanParam(
      name: 'MONITORING_STACK_ENABLED',
      defaultValue: true,
      description: 'Deploy Grafana/Prometheus (Ansible MONITORING stage / 32_setup_monitoring_stack.yml). Requires PORTAL stage first. Sets monitoring_stack_enabled.'
    )
    booleanParam(
      name: 'DEPLOYMENT_PORTAL_ENABLED',
      defaultValue: true,
      description: 'Bootstrap portal before CM (10_setup_deployment_portal). Index is refreshed incrementally after Identity, CM, TLS, CDH, monitoring, and ECS (35_refresh in each Ansible phase).'
    )
    booleanParam(
      name: 'ECS_DATA_SERVICES_DEPLOY_ENABLED',
      defaultValue: false,
      description: 'Run 34_setup_ecs_data_services.yml after ECS phase 5 when checked. Requires ecs_control_plane_url and API access key in ANSIBLE_GROUP_VARS_YAML (create key in ECS console first).'
    )
  }

  options {
    timeout(time: 8, unit: 'HOURS')
    timestamps()
    ansiColor('xterm')
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  environment {
    LANG = 'C.UTF-8'
    LC_ALL = 'C.UTF-8'
    UI_ASCII = '1'
    // Wrapper UI stays plain ASCII; Ansible colors go to console (ansiColor) — artifact logs strip ANSI.
    FORCE_COLOR = '0'
    UI_COLOR = '0'
    ANSIBLE_FORCE_COLOR = '1'
    PY_COLORS = '1'
    REPO_ROOT = "${WORKSPACE}"
    LOG_DIR = "${WORKSPACE}/jenkins/artifacts"
    HOL_AUTO_EXEC_DIR = "/home/holautosa/HOL_AUTO_EXEC_DIR"
    JENKINS_OWNER = "${params.OWNER?.trim() ?: ''}"
    JENKINS_ENVIRONMENT = "${params.ENVIRONMENT?.trim() ?: ''}"
    JENKINS_AWS_REGION = "${params.AWS_REGION?.trim() ?: ''}"
    JENKINS_AMI_ID = "${params.AMI_ID?.trim() ?: ''}"
    JENKINS_CLDR_MNGR_COUNT = "${params.CLDR_MNGR_COUNT?.trim() ?: ''}"
    JENKINS_CLDR_MNGR_INSTANCE_TYPE = "${params.CLDR_MNGR_INSTANCE_TYPE?.trim() ?: ''}"
    JENKINS_CLDR_MNGR_VOLUME_SIZE = "${params.CLDR_MNGR_VOLUME_SIZE?.trim() ?: ''}"
    JENKINS_IPA_SERVER_COUNT = "${params.IPA_SERVER_COUNT?.trim() ?: ''}"
    JENKINS_IPA_SERVER_INSTANCE_TYPE = "${params.IPA_SERVER_INSTANCE_TYPE?.trim() ?: ''}"
    JENKINS_PVCBASE_MASTER_COUNT = "${params.PVCBASE_MASTER_COUNT?.trim() ?: ''}"
    JENKINS_PVCBASE_WORKER_COUNT = "${params.PVCBASE_WORKER_COUNT?.trim() ?: ''}"
    JENKINS_PVCBASE_WORKER_INSTANCE_TYPE = "${params.PVCBASE_WORKER_INSTANCE_TYPE?.trim() ?: ''}"
    JENKINS_PVCECS_MASTER_COUNT = "${params.PVCECS_MASTER_COUNT?.trim() ?: ''}"
    JENKINS_PVCECS_WORKER_COUNT = "${params.PVCECS_WORKER_COUNT?.trim() ?: ''}"
    JENKINS_PVCECS_WORKER_INSTANCE_TYPE = "${params.PVCECS_WORKER_INSTANCE_TYPE?.trim() ?: ''}"
    VPC_MODE = "${params.VPC_MODE}"
    SG_MODE = "${params.SG_MODE}"
    JENKINS_VPC_MODE = "${params.VPC_MODE}"
    JENKINS_SG_MODE = "${params.SG_MODE}"
    JENKINS_CREATE_EIP = "${params.CREATE_EIP}"
    JENKINS_VPC_NAME = "${params.VPC_NAME?.trim() ?: ''}"
    JENKINS_VPC_CIDR_BLOCK = "${params.VPC_CIDR_BLOCK?.trim() ?: ''}"
    JENKINS_VPC_AZS = "${params.VPC_AZS?.trim() ?: ''}"
    JENKINS_VPC_PUBLIC_SUBNETS_CIDR = "${params.VPC_PUBLIC_SUBNETS_CIDR?.trim() ?: ''}"
    JENKINS_VPC_PRIVATE_SUBNETS_CIDR = "${params.VPC_PRIVATE_SUBNETS_CIDR?.trim() ?: ''}"
    JENKINS_ENABLE_NAT_GATEWAY = "${params.ENABLE_NAT_GATEWAY}"
    JENKINS_ENABLE_VPN_GATEWAY = "${params.ENABLE_VPN_GATEWAY}"
    JENKINS_EXISTING_SG_NAME = "${params.EXISTING_SG_NAME?.trim() ?: ''}"
    JENKINS_SG_NAME = "${params.SG_NAME?.trim() ?: ''}"
    JENKINS_ALLOW_ALL = "${params.ALLOW_ALL}"
    JENKINS_ALLOWED_CIDRS = "${params.ALLOWED_CIDRS?.trim() ?: ''}"
    JENKINS_ALLOWED_PORTS = "${params.ALLOWED_PORTS?.trim() ?: ''}"
    JENKINS_CLDR_EIP_NAME = "${params.CLDR_EIP_NAME?.trim() ?: ''}"
    TFVARS_FILE = "${params.TFVARS_FILE?.trim() ?: ''}"
    DRY_RUN = "${params.DRY_RUN}"
    CREDENTIALS_USER = "${params.CREDENTIALS_USER?.trim() ?: 'holautosa'}"
    ANSIBLE_CONTROL_VIA_JENKINS = '1'
    CM_API_PREFER_PRIVATE_IP = 'false'
    ANSIBLE_CONTROLLER_OUTSIDE_VPC = 'true'
    DEPLOYMENT_PORTAL_URL_VERIFY_SKIP_VPC = 'true'
    PIPELINE_STAGES = "${params.PIPELINE_STAGES?.trim() ?: ''}"
    VALIDATION_CHECKS = "${params.VALIDATION_CHECKS?.trim() ?: ''}"
    BUILD_RESULT = 'IN_PROGRESS'
    MAIL_TO = "${params.NOTIFICATION_EMAIL?.trim() ?: env.BUILD_USER_EMAIL ?: ''}"
  }

  stages {
    stage('Build') {
      steps {
        script {
          def stages = effectivePipelineStages(params.PIPELINE_STAGES)
          def label = "#${BUILD_NUMBER} — ${stages.join('+')}"
          if (params.DRY_RUN == true || "${params.DRY_RUN}" == 'true') { label += ' (dry-run)' }
          currentBuild.displayName = label
        }
      }
    }

    stage('DRY RUN: Reload Jenkinsfile') {
      when { expression { return isRefreshRequested() } }
      steps {
        sh 'echo "Reloading Jenkinsfile parameters for job ${JOB_NAME} [${BUILD_NUMBER}] (${BUILD_URL})"'
        script {
          currentBuild.result = 'ABORTED'
          currentBuild.description = 'Jenkinsfile parameters reloaded. Re-run Build with Parameters.'
          error('DRY RUN COMPLETED — Jenkinsfile parameters reloaded.')
        }
      }
    }

    stage('Resolve Stages') {
      steps {
        script {
          env.USE_CREDENTIALS_USER_AWS = credentialsUserAwsEnabled() ? 'true' : 'false'
          env.AWS_USE_INSTANCE_ROLE = credentialsUserAwsEnabled() ? 'false' : 'true'
          def cfg = resolvePipelineStages(params.PIPELINE_STAGES, params.VALIDATION_CHECKS)
          env.RUN_VALIDATE = cfg.runValidate
          env.RUN_TERRAFORM = cfg.runTerraform
          env.RUN_ANSIBLE = cfg.runAnsible
          env.ANSIBLE_PHASES = cfg.ansiblePhases
          env.SELECTED_ANSIBLE_STAGES = cfg.selectedAnsibleStages
          env.REQUIRE_INVENTORY = cfg.requireInventory
          env.VALIDATE_INVENTORY = cfg.validateInventory
          env.PIPELINE_ACTION = cfg.summaryLabel
          env.VALIDATION_CHECKS = cfg.validationChecks
          env.REQUIRE_ANSIBLE = cfg.runAnsible
          env.REQUIRE_TERRAFORM = cfg.runTerraform
          echo "Resolved stages: validate=${cfg.runValidate}, terraform=${cfg.runTerraform}, ansible=${cfg.runAnsible}, phases=${cfg.ansiblePhases}"
          echo "Ansible stage order: ${cfg.selectedAnsibleStages ?: '(none)'}"
          echoPipelineStagesQuickReference()
          if (cfg.runValidate != 'true' && cfg.runTerraform != 'true' && cfg.runAnsible != 'true') {
            error("No pipeline work resolved from PIPELINE_STAGES='${params.PIPELINE_STAGES}'. Use valid checkboxes (e.g. CDH_BASE not CDH_INSTALL) or REFRESH_JENKINSFILE=YES.")
          }
          echo "Validation checks: ${cfg.validationChecks}"
          echo "AWS creds: USE_CREDENTIALS_USER_AWS=${env.USE_CREDENTIALS_USER_AWS}, AWS_USE_INSTANCE_ROLE=${env.AWS_USE_INSTANCE_ROLE}"
        }
      }
    }

    stage('Check Parameters') {
      steps {
        script {
          validatePipelineInputs()
        }
      }
    }

    stage('Checkout') {
      steps {
        checkout([
          $class: 'GitSCM',
          branches: [[name: "*/${params.GIT_BRANCH}"]],
          doGenerateSubmoduleConfigurations: false,
          extensions: [[$class: 'CleanBeforeCheckout']],
          userRemoteConfigs: scm.userRemoteConfigs
        ])
        sh 'chmod +x jenkins/scripts/*.sh clone_and_run_terraform.sh clone_and_run_pvc_automation.sh generate_inventory.sh 2>/dev/null || true'
        sh """
          set -euo pipefail
          export CREDENTIALS_USER='${params.CREDENTIALS_USER?.trim() ?: 'holautosa'}'
          export ENVIRONMENT='${params.ENVIRONMENT?.trim() ?: 'development'}'
          export HOL_AUTO_EXEC_DIR='${env.HOL_AUTO_EXEC_DIR}'
          ./jenkins/scripts/setup-holautosa-workdir.sh
        """
      }
    }

    stage('Validate Prerequisites') {
      when { expression { return env.RUN_VALIDATE == 'true' } }
      steps {
        sh '''
          set -euo pipefail
          mkdir -p "${LOG_DIR}"
          export PATH="${HOME}/.local/bin:${PATH}"
          export VALIDATION_CHECKS="${VALIDATION_CHECKS}"
          export REQUIRE_INVENTORY="${REQUIRE_INVENTORY:-false}"
          export VALIDATE_INVENTORY="${VALIDATE_INVENTORY:-false}"
          export REQUIRE_ANSIBLE="${REQUIRE_ANSIBLE:-false}"
          export REQUIRE_TERRAFORM="${REQUIRE_TERRAFORM:-false}"
          export AWS_USE_INSTANCE_ROLE="${AWS_USE_INSTANCE_ROLE:-false}"
          export CREDENTIALS_USER="${CREDENTIALS_USER:-holautosa}"
          ./jenkins/scripts/validate-prereqs.sh
        '''
      }
    }

    stage('Terraform — Provision EC2') {
      when { expression { return env.RUN_TERRAFORM == 'true' } }
      steps {
        sh '''
          set -euo pipefail
          export AWS_USE_INSTANCE_ROLE="${AWS_USE_INSTANCE_ROLE:-false}"
          export CREDENTIALS_USER="${CREDENTIALS_USER:-holautosa}"
          # shellcheck source=jenkins/scripts/aws-credential-check.sh
          source ./jenkins/scripts/aws-credential-check.sh
          aws_apply_instance_role_if_enabled
          ./jenkins/scripts/run-terraform.sh
        '''
      }
    }

    stage('Ansible 1 — Prerequisites') {
      when { expression { return shouldRunAnsibleStage('PREREQS') } }
      steps { script { runAnsibleDeployPhase('1') } }
    }
    stage('Ansible 2 — Deployment Portal (bootstrap)') {
      when { expression { return shouldRunAnsibleStage('PORTAL') && portalDeployEnabled() } }
      steps { script { runAnsibleDeployPhase('portal') } }
    }
    stage('Ansible 3 — Identity') {
      when { expression { return shouldRunAnsibleStage('IDENTITY') } }
      steps { script { runAnsibleDeployPhase('2') } }
    }
    stage('Ansible 4 — CM Install') {
      when { expression { return shouldRunAnsibleStage('CM_INSTALL') } }
      steps { script { runAnsibleDeployPhase('3') } }
    }
    stage('Ansible 5 — CM TLS / Kerberos / LDAP') {
      when { expression { return shouldRunAnsibleStage('CM_TLS_KRB_LDAP') } }
      steps { script { runAnsibleDeployPhase('cm_tls') } }
    }
    stage('Ansible 6 — CDH Base Cluster') {
      when { expression { return shouldRunAnsibleStage('CDH_INSTALL') } }
      steps { script { runAnsibleDeployPhase('cdh') } }
    }
    stage('Ansible 7 — Monitoring Stack') {
      when { expression { return shouldRunAnsibleStage('MONITORING') && monitoringStackEnabled() } }
      steps { script { runAnsibleDeployPhase('monitoring') } }
    }
    stage('Ansible 8 — ECS Cluster') {
      when { expression { return shouldRunAnsibleStage('ECS_INSTALL') } }
      steps { script { runAnsibleDeployPhase('ecs') } }
    }

    stage('Build Summary') {
      steps {
        script {
          sh """
            set -euo pipefail
            export BUILD_RESULT='${currentBuild.currentResult ?: 'SUCCESS'}'
            export PIPELINE_ACTION='${env.PIPELINE_ACTION ?: 'n/a'}'
            export PIPELINE_STAGES='${params.PIPELINE_STAGES ?: ''}'
            export ANSIBLE_PHASES='${env.ANSIBLE_PHASES ?: ''}'
            ./jenkins/scripts/collect-artifacts.sh
            ./jenkins/scripts/build-summary.sh
            if [ -f jenkins/artifacts/access-urls.txt ]; then
              echo '========== CDP access URLs (portal / CM / Caddy) =========='
              cat jenkins/artifacts/access-urls.txt
              echo '=========================================================='
            fi
          """
        }
      }
    }
  }

  post {
    success {
      script {
        env.BUILD_RESULT = 'SUCCESS'
        sh '''
          set -eo pipefail
          export BUILD_RESULT=SUCCESS
          export PIPELINE_ACTION="${PIPELINE_ACTION:-n/a}"
          export PIPELINE_STAGES="${PIPELINE_STAGES:-}"
          ./jenkins/scripts/collect-artifacts.sh || true
          ./jenkins/scripts/build-summary.sh || true
        '''
        archivePipelineArtifacts()
        try {
          sendPipelineEmail(true)
        } catch (Exception e) {
          echo "WARN: success email failed: ${e.message}"
        }
      }
    }

    failure {
      script {
        env.BUILD_RESULT = 'FAILURE'
        def extracted = ''
        try {
          extracted = sh(
            script: './jenkins/scripts/extract-errors.sh 2>/dev/null | tail -60',
            returnStdout: true
          ).trim()
        } catch (ignored) {
          extracted = ''
        }
        if (extracted) {
          currentBuild.description = extracted.take(4000)
          env.ERROR_MESSAGE = extracted.take(4000)
        } else {
          currentBuild.description = 'Pipeline failed — see Jenkins console and attached logs.'
          env.ERROR_MESSAGE = currentBuild.description
        }
        sh '''
          set -eo pipefail
          export BUILD_RESULT=FAILURE
          export ERROR_MESSAGE="${ERROR_MESSAGE:-Pipeline failed}"
          export PIPELINE_ACTION="${PIPELINE_ACTION:-n/a}"
          export PIPELINE_STAGES="${PIPELINE_STAGES:-}"
          ./jenkins/scripts/collect-artifacts.sh || true
          ./jenkins/scripts/build-summary.sh || true
        '''
        archivePipelineArtifacts()
        try {
          sendPipelineEmail(false)
        } catch (Exception e) {
          echo "WARN: failure email failed: ${e.message}"
        }
      }
    }

    unstable {
      script {
        env.BUILD_RESULT = 'UNSTABLE'
        archivePipelineArtifacts()
        try {
          sendPipelineEmail(false)
        } catch (Exception e) {
          echo "WARN: unstable email failed: ${e.message}"
        }
      }
    }

    aborted {
      script {
        env.BUILD_RESULT = 'ABORTED'
      }
    }

    cleanup {
      sh 'echo "Pipeline cleanup complete for build ${BUILD_NUMBER}"'
    }
  }
}

def defaultPipelineStages() {
  return 'VALIDATE,TERRAFORM'
}

def defaultValidationChecks() {
  return 'TOOLS,AWS_CREDS,TFVARS,ANSIBLE_SYNTAX,INVENTORY'
}

def isParamEnabled(def value) {
  if (value == null) {
    return false
  }
  if (value instanceof Boolean) {
    return value
  }
  def text = value.toString().trim()
  if (!text) {
    return false
  }
  return text ==~ /(?i)(Y|YES|T|TRUE|ON|1)/
}

def credentialsUserAwsEnabled() {
  if (params.containsKey('USE_CREDENTIALS_USER_AWS')) {
    return isParamEnabled(params.USE_CREDENTIALS_USER_AWS)
  }
  // Legacy jobs before parameter rename: AWS_USE_INSTANCE_ROLE inverted
  return !isParamEnabled(params.AWS_USE_INSTANCE_ROLE)
}

def isRefreshRequested() {
  def refresh = params.REFRESH_JENKINSFILE
  if (refresh == null) {
    return false
  }
  if (refresh instanceof Boolean) {
    return refresh
  }
  def value = refresh.toString().trim()
  if (!value) {
    return false
  }
  return value ==~ /(?i)(Y|YES|T|TRUE|ON|RUN)/
}

def parseSelectedStages(def csv) {
  if (csv == null) {
    return []
  }
  def text = csv.toString().trim()
  if (!text) {
    return []
  }
  return text.split(',').collect { it.trim() }.findAll { it }
}

def knownPipelineStages() {
  return [
    'VALIDATE', 'TERRAFORM', 'PREREQS', 'IDENTITY', 'CM_INSTALL',
    'CM_TLS_KRB_LDAP', 'CDH_INSTALL', 'PORTAL', 'MONITORING', 'ECS_INSTALL', 'CDH_BASE',
  ]
}

def orderedAnsibleStageIds() {
  return [
    'PREREQS', 'PORTAL', 'IDENTITY', 'CM_INSTALL', 'CM_TLS_KRB_LDAP', 'CDH_INSTALL',
    'MONITORING', 'ECS_INSTALL',
  ]
}

def echoPipelineStagesQuickReference() {
  echo '''PIPELINE_STAGES quick reference (full table: Build parameter PIPELINE_STAGES_REFERENCE or jenkins/README.md):
  VALIDATE → prereqs script | TERRAFORM → EC2/inventory | PREREQS → Ansible 01-09 | PORTAL → bootstrap (10)
  IDENTITY → phase 2 | CM_INSTALL → phase 3 | CM_TLS_KRB_LDAP → TLS/LDAP | CDH_INSTALL → base cluster (31)
  MONITORING → (32) | ECS_INSTALL → (33) | Legacy CDH_BASE → CM_TLS_KRB_LDAP + CDH_INSTALL
  PORTAL may auto-insert when DEPLOYMENT_PORTAL_ENABLED and CM/CDH/ECS stages are selected without PORTAL.'''
}

def ansiblePhaseForStage(String stageId) {
  def map = [
    'PREREQS'         : '1',
    'IDENTITY'        : '2',
    'CM_INSTALL'      : '3',
    'PORTAL'          : 'portal',
    'CM_TLS_KRB_LDAP' : 'cm_tls',
    'CDH_INSTALL'     : 'cdh',
    'MONITORING'      : 'monitoring',
    'ECS_INSTALL'     : 'ecs',
  ]
  return map[stageId]
}

// Legacy Jenkins job UI values (before checkbox rename) and common typos.
def pipelineStageAliases() {
  return [
    'CDH'        : 'CDH_INSTALL',
    'ECS'        : 'ECS_INSTALL',
  ]
}

def expandPipelineStageTokens(List stages) {
  def result = []
  stages.each { token ->
    if (token == 'CDH_BASE') {
      result << 'CM_TLS_KRB_LDAP'
      result << 'CDH_INSTALL'
    } else if (!result.contains(token)) {
      result << token
    }
  }
  return result
}

def portalDeployEnabled() {
  return isParamEnabled(params.DEPLOYMENT_PORTAL_ENABLED)
}

def monitoringStackEnabled() {
  return isParamEnabled(params.MONITORING_STACK_ENABLED)
}

def shouldRunAnsibleStage(String stageId) {
  if (env.RUN_ANSIBLE != 'true') {
    return false
  }
  def selected = (env.SELECTED_ANSIBLE_STAGES ?: '').split(',').collect { it.trim() }.findAll { it }
  return selected.contains(stageId)
}

def normalizePipelineStageToken(String token) {
  def aliases = pipelineStageAliases()
  def upper = token?.trim()?.toUpperCase()
  if (!upper) {
    return upper
  }
  return aliases.get(upper, upper)
}

def effectivePipelineStages(def csv) {
  def stages = parseSelectedStages(csv).collect { normalizePipelineStageToken(it) }
  if (stages.isEmpty()) {
    echo "PIPELINE_STAGES not set — using default: ${defaultPipelineStages()}"
    stages = parseSelectedStages(defaultPipelineStages())
  }
  return expandPipelineStageTokens(stages)
}

def effectiveValidationChecks(def csv) {
  def checks = (csv?.toString()?.trim())
  if (!checks) {
    echo "VALIDATION_CHECKS not set — using default: ${defaultValidationChecks()}"
    return defaultValidationChecks()
  }
  return checks
}

def resolvePipelineStages(def stagesCsv, def validationCsv) {
  def stages = effectivePipelineStages(stagesCsv)
  def ansibleStageIds = orderedAnsibleStageIds().findAll { stages.contains(it) }
  if (portalDeployEnabled() && !ansibleStageIds.contains('PORTAL')) {
    def needsPortal = ansibleStageIds.any {
      it in ['IDENTITY', 'CM_INSTALL', 'CM_TLS_KRB_LDAP', 'CDH_INSTALL', 'MONITORING', 'ECS_INSTALL']
    }
    if (needsPortal) {
      def prereqIdx = ansibleStageIds.indexOf('PREREQS')
      if (prereqIdx >= 0) {
        ansibleStageIds = ansibleStageIds[0..prereqIdx] + ['PORTAL'] + ansibleStageIds.drop(prereqIdx + 1)
      } else {
        ansibleStageIds = ['PORTAL'] + ansibleStageIds
      }
      echo 'INFO: DEPLOYMENT_PORTAL_ENABLED — auto-including PORTAL bootstrap before CM (incremental index refresh in later phases).'
    }
  }
  def ansiblePhases = ansibleStageIds.collect { ansiblePhaseForStage(it) }
  def runTerraform = stages.contains('TERRAFORM') ? 'true' : 'false'
  def runAnsible = ansiblePhases.isEmpty() ? 'false' : 'true'
  def runValidate = stages.contains('VALIDATE') ? 'true' : 'false'
  def requireInventory = (runAnsible == 'true' && runTerraform != 'true') ? 'true' : 'false'
  def validationChecks = effectiveValidationChecks(validationCsv)
  if (requireInventory == 'true' && !validationChecks.contains('INVENTORY')) {
    validationChecks = "${validationChecks},INVENTORY"
  }
  def summary = stages.isEmpty() ? 'none' : stages.join('+')
  return [
    runValidate           : runValidate,
    runTerraform            : runTerraform,
    runAnsible              : runAnsible,
    ansiblePhases           : ansiblePhases.join(','),
    selectedAnsibleStages   : ansibleStageIds.join(','),
    requireInventory        : requireInventory,
    validateInventory       : requireInventory,
    validationChecks        : validationChecks,
    summaryLabel            : summary,
  ]
}

def runAnsibleDeployPhase(String phase) {
  writeAnsibleGroupVarsFragmentFile()
  def licenseFile = writeCmLicenseContentFile()
  if (ansibleGroupVarsYamlHasKeys(params.ANSIBLE_GROUP_VARS_YAML?.toString())) {
    def yamlCheck = sh(
      script: '''
        set -euo pipefail
        export ANSIBLE_GROUP_VARS_FILE="${ANSIBLE_GROUP_VARS_FILE:?}"
        python3 jenkins/scripts/render-ansible-group-vars-override.py --validate-only /dev/null
      ''',
      returnStatus: true,
      env: [
        ANSIBLE_GROUP_VARS_FILE: "${env.WORKSPACE}/jenkins/artifacts/ansible-group-vars-fragment.yaml",
      ],
    )
    if (yamlCheck != 0) {
      validationFail('ANSIBLE_GROUP_VARS_YAML is invalid or contains disallowed keys — see jenkins/ansible-group-vars-allowed-keys.yaml')
    }
  }
  def cmPasswordParam = ''
  if (params.CM_REPO_PASSWORD) {
    cmPasswordParam = "${params.CM_REPO_PASSWORD}".trim()
  }
  def prefix = """
    set -euo pipefail
    export DEPLOY_PHASE='${phase}'
    export MONITORING_STACK_ENABLED='${params.MONITORING_STACK_ENABLED}'
    export DEPLOYMENT_PORTAL_ENABLED='${params.DEPLOYMENT_PORTAL_ENABLED}'
    export ECS_DATA_SERVICES_DEPLOY_ENABLED='${params.ECS_DATA_SERVICES_DEPLOY_ENABLED}'
    export ECS_IAM_BOOTSTRAP_ACCESS_KEY_ID='${shellEscape(env.ECS_IAM_BOOTSTRAP_ACCESS_KEY_ID ?: '')}'
    export ECS_IAM_BOOTSTRAP_PRIVATE_KEY='${shellEscape(env.ECS_IAM_BOOTSTRAP_PRIVATE_KEY ?: '')}'
    export REQUIRE_INVENTORY=true
    export ANSIBLE_GROUP_VARS_FILE='${env.WORKSPACE}/jenkins/artifacts/ansible-group-vars-fragment.yaml'
    export CM_REPO_USERNAME='${shellEscape(params.CM_REPO_USERNAME?.trim())}'
    export LICENSE_FILE='${licenseFile ? shellEscape(licenseFile) : ''}'
    export CM_LICENSE_CONTENT_FILE='${licenseFile ? shellEscape(licenseFile) : ''}'
  """
  echo "Running Ansible DEPLOY_PHASE=${phase}"
  if (cmPasswordParam) {
    withEnv(["CM_REPO_PASSWORD=${cmPasswordParam}"]) {
      sh prefix + './jenkins/scripts/run-ansible.sh'
    }
  } else {
    sh prefix + './jenkins/scripts/run-ansible.sh'
  }
}

def validationFail(String message) {
  def RED_BOLD = "\u001B[1;31m"
  def RESET = "\u001B[0m"
  error "${RED_BOLD}❗ ERROR: ${message} ❗${RESET}"
}

def shellEscape(String value) {
  if (value == null) {
    return ''
  }
  return value.toString().replace('\\', '\\\\').replace("'", "'\\''")
}

def writeAnsibleGroupVarsFragmentFile() {
  def fragment = params.ANSIBLE_GROUP_VARS_YAML?.toString() ?: ''
  writeFile file: "${env.WORKSPACE}/jenkins/artifacts/ansible-group-vars-fragment.yaml", text: fragment
}

def cmLicenseContentProvided(String licenseText) {
  if (!licenseText?.trim()) {
    return false
  }
  return licenseText.split('\n').any { line ->
    def t = line.trim()
    t && !t.startsWith('#')
  }
}

def writeCmLicenseContentFile() {
  def content = params.CM_LICENSE_CONTENT?.toString() ?: ''
  if (!cmLicenseContentProvided(content)) {
    return null
  }
  def path = "${env.WORKSPACE}/jenkins/artifacts/cm-license.txt"
  writeFile file: path, text: content
  echo 'CM license content provided via Jenkins parameter (written to jenkins/artifacts/cm-license.txt).'
  return path
}

def ansibleGroupVarsYamlHasKeys(String yamlText) {
  if (!yamlText?.trim()) {
    return false
  }
  def stripped = yamlText.replaceAll('(?m)^\\s*#.*$', '').trim()
  if (!stripped) {
    return false
  }
  return stripped.split('\n').any { line ->
    def t = line.trim()
    t && !t.startsWith('#') && t.contains(':')
  }
}

def validatePipelineInputs() {
  if (isRefreshRequested()) {
    echo 'REFRESH_JENKINSFILE=YES — skipping input validation.'
    return
  }

  def stages = effectivePipelineStages(params.PIPELINE_STAGES)
  if (stages.isEmpty()) {
    validationFail('PIPELINE_STAGES is empty. Select at least one stage checkbox, or set REFRESH_JENKINSFILE=YES to reload parameters after Jenkinsfile changes.')
  }

  def known = knownPipelineStages()
  def unknown = stages.findAll { !known.contains(it) }
  if (!unknown.isEmpty()) {
    validationFail("Unknown PIPELINE_STAGES value(s): ${unknown.join(', ')}. Valid checkboxes: ${orderedAnsibleStageIds().plus(['VALIDATE', 'TERRAFORM', 'CDH_BASE']).join(', ')}. Run REFRESH_JENKINSFILE=YES after Jenkinsfile changes.")
  }

  def rawStages = parseSelectedStages(params.PIPELINE_STAGES)
  def legacy = rawStages.findAll { pipelineStageAliases().containsKey(it.trim().toUpperCase()) }
  if (!legacy.isEmpty()) {
    echo "WARN: Legacy PIPELINE_STAGES token(s) ${legacy.join(', ')} → ${legacy.collect { normalizePipelineStageToken(it) }.join(', ')}"
  }

  def awsRegionRegex = /^(us|eu|ap|sa|ca|me|af|il|cn|us-gov)-[a-z]+-\d{1}$/
  def envNameRegex = /^[a-zA-Z][a-zA-Z0-9-]{2,31}$/
  def amiRegex = /^ami-[a-z0-9]+$/
  def instanceTypeRegex = /^[a-z][0-9]+[a-z]?\.[a-z0-9]+$/
  def emailRegex = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/

  def region = params.AWS_REGION?.trim()
  if (region && !region.matches(awsRegionRegex)) {
    validationFail("AWS_REGION '${region}' is not a valid AWS region (e.g. ap-southeast-1).")
  }

  def environmentName = params.ENVIRONMENT?.trim()
  if (environmentName && !environmentName.matches(envNameRegex)) {
    validationFail("ENVIRONMENT '${environmentName}' must be 3-32 chars, start with a letter, and use only letters, digits, or hyphens.")
  }

  def owner = params.OWNER?.trim()
  if (owner && owner.length() > 64) {
    validationFail('OWNER must be 64 characters or fewer.')
  }

  if (stages.contains('TERRAFORM') || stages.any { it in orderedAnsibleStageIds() }) {
    if (!owner) {
      echo 'WARN: OWNER not set in Jenkins UI — must be present in tfvars or validation will fail later.'
    }
  }

  if (stages.contains('TERRAFORM')) {
    def vpcMode = params.VPC_MODE?.trim() ?: 'USE_DEFAULT'
    def sgMode = params.SG_MODE?.trim() ?: 'USE_EXISTING'
    echo "Terraform infra: VPC_MODE=${vpcMode}, SG_MODE=${sgMode}, CREATE_EIP=${params.CREATE_EIP}"
    if (vpcMode == 'CREATE_NEW') {
      def cidr = params.VPC_CIDR_BLOCK?.trim()
      if (!cidr || !cidr.matches(/^\\d+\\.\\d+\\.\\d+\\.\\d+\\/\\d+$/)) {
        validationFail("VPC_CIDR_BLOCK '${cidr}' is invalid for VPC_MODE=CREATE_NEW (expected e.g. 172.16.0.0/16).")
      }
      if (sgMode == 'USE_EXISTING') {
        echo 'WARN: VPC_MODE=CREATE_NEW + SG_MODE=USE_EXISTING — EXISTING_SG_NAME must be a security group already in that new VPC (or use sg-id after VPC exists). First deploy in a new VPC: prefer SG_MODE=CREATE_NEW.'
      }
    }
    if (vpcMode == 'USE_DEFAULT' && sgMode == 'USE_EXISTING') {
      echo 'INFO: USE_DEFAULT + USE_EXISTING — SG name is resolved in the account default VPC; validation checks SG exists there when TFVARS/AWS pre-check runs.'
    }
  }

  def ami = params.AMI_ID?.trim()
  if (ami && !ami.matches(amiRegex)) {
    validationFail("AMI_ID '${ami}' is invalid (expected format: ami-xxxxxxxx).")
  }

  def countParams = [
    'CLDR_MNGR_COUNT', 'CLDR_MNGR_VOLUME_SIZE',
    'IPA_SERVER_COUNT', 'PVCBASE_MASTER_COUNT', 'PVCBASE_WORKER_COUNT',
    'PVCECS_MASTER_COUNT', 'PVCECS_WORKER_COUNT',
  ]
  countParams.each { name ->
    def val = params."${name}"?.trim()
    if (val) {
      if (!val.isInteger()) {
        validationFail("${name} must be a positive integer when set (got '${val}').")
      }
      if (val.toInteger() < 1) {
        validationFail("${name} must be >= 1 when set.")
      }
    }
  }

  def typeParams = [
    'CLDR_MNGR_INSTANCE_TYPE', 'IPA_SERVER_INSTANCE_TYPE',
    'PVCBASE_WORKER_INSTANCE_TYPE', 'PVCECS_WORKER_INSTANCE_TYPE',
  ]
  typeParams.each { name ->
    def val = params."${name}"?.trim()
    if (val && !val.matches(instanceTypeRegex)) {
      validationFail("${name} '${val}' does not look like a valid EC2 instance type (e.g. m5.4xlarge).")
    }
  }

  def branch = params.GIT_BRANCH?.trim()
  if (!branch) {
    validationFail('GIT_BRANCH cannot be empty.')
  }
  if (branch.contains(' ') || branch.contains('..')) {
    validationFail("GIT_BRANCH '${branch}' contains invalid characters.")
  }

  def tfvarsPath = params.TFVARS_FILE?.trim()
  if (tfvarsPath && (tfvarsPath.contains('..') || tfvarsPath.startsWith('/'))) {
    validationFail("TFVARS_FILE must be a relative path within the workspace (got '${tfvarsPath}').")
  }

  def email = params.NOTIFICATION_EMAIL?.trim()
  def checks = params.VALIDATION_CHECKS?.toString() ?: ''
  if (email && checks.contains('EMAIL_FORMAT') && !email.matches(emailRegex)) {
    validationFail("NOTIFICATION_EMAIL '${email}' is not a valid email address.")
  }

  if (stages.contains('ECS_INSTALL') && !stages.contains('CDH_INSTALL') && !stages.contains('CM_TLS_KRB_LDAP') && !stages.contains('TERRAFORM')) {
    echo 'WARN: ECS_INSTALL without CDH_INSTALL — ensure base cluster already exists.'
  }
  if (stages.contains('CM_INSTALL') && !stages.contains('PREREQS') && !stages.contains('TERRAFORM')) {
    echo 'WARN: CM_INSTALL without PREREQS — ensure prerequisites were applied previously.'
  }
  if (stages.contains('MONITORING') && !stages.contains('PORTAL')) {
    echo 'WARN: MONITORING without PORTAL — ensure 10_setup_deployment_portal.yml ran previously.'
  }
  if (stages.contains('CM_TLS_KRB_LDAP') && !stages.contains('CM_INSTALL') && !stages.contains('TERRAFORM')) {
    echo 'WARN: CM_TLS_KRB_LDAP without CM_INSTALL — ensure Cloudera Manager is installed.'
  }
  def cmStages = ['CM_INSTALL', 'CM_TLS_KRB_LDAP', 'CDH_INSTALL', 'ECS_INSTALL']
  if (stages.any { it in cmStages }) {
    if (!cmLicenseContentProvided(params.CM_LICENSE_CONTENT?.toString() ?: '')) {
      echo 'INFO: CM_LICENSE_CONTENT empty — CM phase uses agent *license* file or trial license.'
    }
    // Do not read params.CM_REPO_PASSWORD here — Jenkins blocks password params outside withCredentials/withEnv in stages.
    if (!params.CM_REPO_USERNAME?.trim()) {
      echo 'INFO: CM_REPO_USERNAME empty — archive creds may come from *info.txt or group_vars/all.yml.'
    }
  }
  if (stages.contains('TERRAFORM') && stages.any { it in orderedAnsibleStageIds() } && params.DRY_RUN) {
    echo 'INFO: DRY_RUN applies to both Terraform plan and Ansible check mode in this build.'
  }

  echo "Input validation passed for stages: ${stages.join(', ')}"
}

def archivePipelineArtifacts() {
  def patterns = [
    'jenkins/artifacts/build-summary.txt',
    'jenkins/artifacts/cm-access.txt',
    'jenkins/artifacts/access-urls.txt',
    'jenkins/artifacts/inventory.ini',
    'jenkins/artifacts/terraform-*.log',
    'jenkins/artifacts/ansible-*.log',
    'jenkins/artifacts/validate-*.log',
    'jenkins/artifacts/error-summary.txt',
    'jenkins/artifacts/terraform-state-summary.json',
    'jenkins/artifacts/*.pem',
    'ansible-playbooks/inventory.ini',
  ].join(',')
  archiveArtifacts artifacts: patterns, allowEmptyArchive: true, fingerprint: true
}

def sendPipelineEmail(boolean success) {
  if (!env.MAIL_TO?.trim()) {
    echo 'No NOTIFICATION_EMAIL or BUILD_USER_EMAIL — skipping email.'
    return
  }

  def statusIcon = success ? '✅' : '❌'
  def statusText = success ? 'Completed Successfully' : 'Failed'
  def color = success ? '#4CAF50' : '#E53935'
  def errorBlock = ''
  if (!success) {
    def err = (currentBuild.description ?: env.ERROR_MESSAGE ?: 'See attached logs.').replace('\n', '<br/>')
    errorBlock = """
      <h4 style="color:${color};">Error Summary</h4>
      <pre style="background:#fff3f3;padding:12px;border:1px solid #ffcdd2;white-space:pre-wrap;">${err}</pre>
    """
  }

  def summaryFile = "${env.WORKSPACE}/jenkins/artifacts/build-summary.txt"
  def summaryText = fileExists(summaryFile) ? readFile(summaryFile).take(8000).replace('\n', '<br/>') : 'n/a'
  def stageInfo = env.PIPELINE_ACTION ?: params.PIPELINE_STAGES ?: 'n/a'
  def phaseInfo = env.ANSIBLE_PHASES ?: 'n/a'

  def attachmentList = []
  ['build-summary.txt', 'cm-access.txt', 'access-urls.txt', "terraform-${env.BUILD_NUMBER}.log", 'inventory.ini', 'error-summary.txt'].each { name ->
    if (fileExists("${env.WORKSPACE}/jenkins/artifacts/${name}")) {
      attachmentList << "jenkins/artifacts/${name}"
    }
  }
  def phaseLogs = sh(
    script: "ls ${env.WORKSPACE}/jenkins/artifacts/ansible-${env.BUILD_NUMBER}-phase*.log 2>/dev/null || true",
    returnStdout: true
  ).trim()
  if (phaseLogs) {
    phaseLogs.split('\n').each { path ->
      def rel = path.replace("${env.WORKSPACE}/", '')
      if (rel) {
        attachmentList << rel
      }
    }
  }
  if (fileExists("${env.WORKSPACE}/ansible-playbooks/inventory.ini")) {
    attachmentList << 'ansible-playbooks/inventory.ini'
  }
  def pemFiles = sh(
    script: "ls ${env.WORKSPACE}/jenkins/artifacts/*.pem 2>/dev/null || true",
    returnStdout: true
  ).trim()
  if (pemFiles) {
    pemFiles.split('\n').each { path ->
      def rel = path.replace("${env.WORKSPACE}/", '')
      if (rel) {
        attachmentList << rel
      }
    }
  }

  def cmAccessFile = "${env.WORKSPACE}/jenkins/artifacts/cm-access.txt"
  def cmAccessHtml = ''
  if (fileExists(cmAccessFile)) {
    def cmText = readFile(cmAccessFile).take(4000)
      .replace('&', '&amp;')
      .replace('<', '&lt;')
      .replace('>', '&gt;')
    cmAccessHtml = """
    <h4 style="color:#1565C0;">SSH &amp; Cloudera Manager Access</h4>
    <pre style="background:#e3f2fd;padding:12px;border:1px solid #90caf9;white-space:pre-wrap;font-size:13px;">${cmText}</pre>
    """
  }

  def accessUrlsFile = "${env.WORKSPACE}/jenkins/artifacts/access-urls.txt"
  def accessUrlsHtml = ''
  if (fileExists(accessUrlsFile)) {
    def urlText = readFile(accessUrlsFile).take(6000)
      .replaceAll('\u001B\\[[0-9;]*[a-zA-Z]', '')
      .replaceAll('\u001B\\][^\u0007]*(\u0007|\u001B\\\\)', '')
      .replace('&', '&amp;')
      .replace('<', '&lt;')
      .replace('>', '&gt;')
    accessUrlsHtml = """
    <h4 style="color:#2E7D32;">Portal, CM, Caddy &amp; Monitoring URLs</h4>
    <pre style="background:#e8f5e9;padding:12px;border:1px solid #a5d6a7;white-space:pre-wrap;font-size:13px;">${urlText}</pre>
    """
  }

  emailext(
    to: env.MAIL_TO,
    subject: "${statusIcon} Jenkins ${statusText}: ${env.JOB_NAME} [${env.BUILD_NUMBER}] — ${stageInfo}",
    mimeType: 'text/html',
    attachmentsPattern: attachmentList.unique().join(','),
    body: """
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"/></head>
<body style="font-family:Arial,sans-serif;color:#333;">
  <div style="border:1px solid #e0e0e0;padding:16px;border-radius:8px;background:#f9f9f9;">
    <h3 style="color:${color};">${statusIcon} CDP On-Prem Automation — ${statusText}</h3>
    <table style="border-collapse:collapse;width:100%;">
      <tr><th style="text-align:left;padding:8px;border:1px solid #ddd;background:#f2f2f2;">Job</th><td style="padding:8px;border:1px solid #ddd;">${env.JOB_NAME}</td></tr>
      <tr><th style="text-align:left;padding:8px;border:1px solid #ddd;background:#f2f2f2;">Build</th><td style="padding:8px;border:1px solid #ddd;">#${env.BUILD_NUMBER}</td></tr>
      <tr><th style="text-align:left;padding:8px;border:1px solid #ddd;background:#f2f2f2;">Stages</th><td style="padding:8px;border:1px solid #ddd;">${stageInfo} (ansible phases: ${phaseInfo}, dry-run=${params.DRY_RUN})</td></tr>
      <tr><th style="text-align:left;padding:8px;border:1px solid #ddd;background:#f2f2f2;">Build URL</th><td style="padding:8px;border:1px solid #ddd;"><a href="${env.BUILD_URL}">${env.BUILD_URL}</a></td></tr>
      <tr><th style="text-align:left;padding:8px;border:1px solid #ddd;background:#f2f2f2;">Triggered by</th><td style="padding:8px;border:1px solid #ddd;">${env.BUILD_USER ?: 'n/a'}</td></tr>
    </table>
    ${errorBlock}
    ${cmAccessHtml}
    ${accessUrlsHtml}
    <h4>Deployment Summary</h4>
    <pre style="background:#fff;padding:12px;border:1px solid #ddd;white-space:pre-wrap;">${summaryText}</pre>
    <p style="font-size:12px;color:#777;">Attached when available: SSH private key (*.pem), cm-access.txt, access-urls.txt, build summary, inventory, stage logs.</p>
  </div>
</body>
</html>
"""
  )
}
