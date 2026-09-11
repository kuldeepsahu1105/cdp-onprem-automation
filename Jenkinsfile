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
      value: 'VALIDATE,TERRAFORM,PREREQS,IDENTITY,CM_INSTALL,CDH_BASE,ECS_INSTALL',
      defaultValue: 'VALIDATE,TERRAFORM',
      multiSelectDelimiter: ',',
      description: 'Select stages to run (executed in order: Validate → Terraform → Ansible phases 1→5)'
    )
    extendedChoice(
      name: 'VALIDATION_CHECKS',
      type: 'PT_CHECKBOX',
      value: 'TOOLS,AWS_CREDS,TFVARS,ANSIBLE_SYNTAX,INVENTORY,EMAIL_FORMAT',
      defaultValue: 'TOOLS,AWS_CREDS,TFVARS,ANSIBLE_SYNTAX,INVENTORY',
      multiSelectDelimiter: ',',
      description: 'Validation checks when VALIDATE stage is selected (INVENTORY auto-enabled for Ansible-only runs)'
    )
    booleanParam(name: 'DRY_RUN', defaultValue: false, description: 'Terraform plan only / Ansible --check --diff (no apply)')
    booleanParam(name: 'USE_CREDENTIALS_USER_AWS', defaultValue: true, description: 'Use CREDENTIALS_USER ~/.aws credentials (default on — uncheck to use EC2 instance IAM role via IMDS)')
    string(name: 'CREDENTIALS_USER', defaultValue: 'holautosa', description: 'OS user whose ~/.aws and ~/.ssh credentials to use (read-only; files not modified)')
    choice(
      name: 'VPC_MODE',
      choices: ['USE_DEFAULT', 'CREATE_NEW'],
      description: 'VPC: USE_DEFAULT = account default VPC (create_vpc=false). CREATE_NEW = new VPC — set VPC fields below.'
    )
    choice(
      name: 'SG_MODE',
      choices: ['USE_EXISTING', 'CREATE_NEW'],
      description: 'Security group: USE_EXISTING = lookup by name/sg-id (default {ENVIRONMENT}-pvc_cluster_sg). CREATE_NEW = Terraform creates SG — set SG fields below.'
    )
    booleanParam(name: 'CREATE_EIP', defaultValue: true, description: 'Allocate Elastic IP for Cloudera Manager (cldr-mngr)')
    string(name: 'VPC_NAME', defaultValue: '', description: 'CREATE_NEW VPC: name (empty = {ENVIRONMENT}-cldr-vpc)')
    string(name: 'VPC_CIDR_BLOCK', defaultValue: '172.16.0.0/16', description: 'CREATE_NEW VPC: CIDR block')
    string(name: 'VPC_AZS', defaultValue: '["ap-southeast-1a","ap-southeast-1b"]', description: 'CREATE_NEW VPC: JSON AZ list')
    string(name: 'VPC_PUBLIC_SUBNETS_CIDR', defaultValue: '["172.16.0.0/24"]', description: 'CREATE_NEW VPC: JSON public subnet CIDRs')
    string(name: 'VPC_PRIVATE_SUBNETS_CIDR', defaultValue: '[]', description: 'CREATE_NEW VPC: JSON private subnet CIDRs')
    booleanParam(name: 'ENABLE_NAT_GATEWAY', defaultValue: false, description: 'CREATE_NEW VPC: enable NAT gateway')
    booleanParam(name: 'ENABLE_VPN_GATEWAY', defaultValue: false, description: 'CREATE_NEW VPC: enable VPN gateway')
    string(name: 'EXISTING_SG_NAME', defaultValue: '', description: 'USE_EXISTING SG: sg-id or name (empty = {ENVIRONMENT}-pvc_cluster_sg)')
    string(name: 'SG_NAME', defaultValue: '', description: 'CREATE_NEW SG: name (empty = {ENVIRONMENT}-pvc_cluster_sg)')
    booleanParam(name: 'ALLOW_ALL', defaultValue: false, description: 'CREATE_NEW SG: unchecked (default) = all protocols from ALLOWED_CIDRS only; checked = all protocols from 0.0.0.0/0')
    string(name: 'ALLOWED_CIDRS', defaultValue: '["137.83.231.109/32", "137.83.231.11/32", "208.127.31.110/32", "208.127.31.11/32", "139.180.248.227/32", "54.254.32.236/32"]', description: 'CREATE_NEW SG when ALLOW_ALL=false: JSON source CIDRs (all protocols/ports)')
    string(name: 'ALLOWED_PORTS', defaultValue: '[22,443,80,7180,7183,7182]', description: 'Legacy/unused — ingress no longer restricts to TCP ports (kept for tfvars compatibility)')
    string(name: 'CLDR_EIP_NAME', defaultValue: '', description: 'Elastic IP name (empty = {ENVIRONMENT}-cldr-mngr-eip)')
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
  }

  options {
    timeout(time: 8, unit: 'HOURS')
    timestamps()
    ansiColor('xterm')
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  environment {
    LANG = 'C.UTF-8'
    FORCE_COLOR = '1'
    UI_COLOR = '1'
    ANSIBLE_FORCE_COLOR = 'true'
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
          env.REQUIRE_INVENTORY = cfg.requireInventory
          env.VALIDATE_INVENTORY = cfg.validateInventory
          env.PIPELINE_ACTION = cfg.summaryLabel
          env.VALIDATION_CHECKS = cfg.validationChecks
          env.REQUIRE_ANSIBLE = cfg.runAnsible
          env.REQUIRE_TERRAFORM = cfg.runTerraform
          echo "Resolved stages: validate=${cfg.runValidate}, terraform=${cfg.runTerraform}, ansible=${cfg.runAnsible}, phases=${cfg.ansiblePhases}"
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

    stage('Ansible Deploy') {
      when { expression { return env.RUN_ANSIBLE == 'true' } }
      steps {
        script {
          def phases = env.ANSIBLE_PHASES.split(',').findAll { it?.trim() }
          for (phase in phases) {
            echo "Running Ansible deploy phase ${phase}"
            sh """
              set -euo pipefail
              export DEPLOY_PHASE='${phase}'
              export REQUIRE_INVENTORY=true
              ./jenkins/scripts/run-ansible.sh
            """
          }
        }
      }
    }

    stage('Build Summary') {
      steps {
        script {
          sh """
            set -euo pipefail
            export BUILD_RESULT='${currentBuild.currentResult ?: 'SUCCESS'}'
            export PIPELINE_ACTION='${env.PIPELINE_ACTION ?: 'n/a'}'
            export PIPELINE_STAGES='${params.PIPELINE_STAGES ?: ''}'
            ./jenkins/scripts/collect-artifacts.sh
            ./jenkins/scripts/build-summary.sh
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

def effectivePipelineStages(def csv) {
  def stages = parseSelectedStages(csv)
  if (stages.isEmpty()) {
    echo "PIPELINE_STAGES not set — using default: ${defaultPipelineStages()}"
    return parseSelectedStages(defaultPipelineStages())
  }
  return stages
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
  def ansibleMap = [
    'PREREQS'    : '1',
    'IDENTITY'   : '2',
    'CM_INSTALL' : '3',
    'CDH_BASE'   : '4',
    'ECS_INSTALL': '5',
  ]
  def ansiblePhases = stages.findAll { ansibleMap.containsKey(it) }.collect { ansibleMap[it] }
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
    runValidate      : runValidate,
    runTerraform     : runTerraform,
    runAnsible       : runAnsible,
    ansiblePhases    : ansiblePhases.join(','),
    requireInventory : requireInventory,
    validateInventory: requireInventory,
    validationChecks : validationChecks,
    summaryLabel     : summary,
  ]
}

def validationFail(String message) {
  def RED_BOLD = "\u001B[1;31m"
  def RESET = "\u001B[0m"
  error "${RED_BOLD}❗ ERROR: ${message} ❗${RESET}"
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

  if (stages.contains('TERRAFORM') || stages.any { it in ['PREREQS', 'IDENTITY', 'CM_INSTALL', 'CDH_BASE', 'ECS_INSTALL'] }) {
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

  if (stages.contains('ECS_INSTALL') && !stages.contains('CDH_BASE') && !stages.contains('TERRAFORM')) {
    echo 'WARN: ECS_INSTALL without CDH_BASE — ensure base cluster already exists.'
  }
  if (stages.contains('CM_INSTALL') && !stages.contains('PREREQS') && !stages.contains('TERRAFORM')) {
    echo 'WARN: CM_INSTALL without PREREQS — ensure prerequisites were applied previously.'
  }
  if (stages.contains('TERRAFORM') && stages.any { it in ['PREREQS', 'IDENTITY', 'CM_INSTALL', 'CDH_BASE', 'ECS_INSTALL'] } && params.DRY_RUN) {
    echo 'INFO: DRY_RUN applies to both Terraform plan and Ansible check mode in this build.'
  }

  echo "Input validation passed for stages: ${stages.join(', ')}"
}

def archivePipelineArtifacts() {
  def patterns = [
    'jenkins/artifacts/build-summary.txt',
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
  ['build-summary.txt', "terraform-${env.BUILD_NUMBER}.log", 'inventory.ini', 'error-summary.txt'].each { name ->
    if (fileExists("${env.WORKSPACE}/jenkins/artifacts/${name}")) {
      attachmentList << "jenkins/artifacts/${name}"
    }
  }
  ['1', '2', '3', '4', '5'].each { phase ->
    def logName = "ansible-${env.BUILD_NUMBER}-phase${phase}.log"
    if (fileExists("${env.WORKSPACE}/jenkins/artifacts/${logName}")) {
      attachmentList << "jenkins/artifacts/${logName}"
    }
  }
  if (fileExists("${env.WORKSPACE}/ansible-playbooks/inventory.ini")) {
    attachmentList << 'ansible-playbooks/inventory.ini'
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
    <h4>Deployment Summary</h4>
    <pre style="background:#fff;padding:12px;border:1px solid #ddd;white-space:pre-wrap;">${summaryText}</pre>
    <p style="font-size:12px;color:#777;">Attached: build summary, stage logs, inventory (when available).</p>
  </div>
</body>
</html>
"""
  )
}
