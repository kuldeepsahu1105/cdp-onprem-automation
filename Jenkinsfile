pipeline {
  agent any

  parameters {
    choice(
      name: 'PIPELINE_ACTION',
      choices: [
        'validate',
        'terraform-only',
        'prereqs-only',
        'identity-only',
        'cm-install',
        'cdh-base',
        'ecs-install',
        'ansible-all',
        'full'
      ],
      description: '''What to run:
validate = checks only
terraform-only = EC2/inventory only (override counts/sizes/prefix below)
prereqs-only = Ansible phase 1 | identity-only = phase 2 | cm-install = phase 3
cdh-base = phase 4 | ecs-install = phase 5 | ansible-all = all Ansible phases
full = terraform-only then ansible-all'''
    )
    booleanParam(name: 'DRY_RUN', defaultValue: false, description: 'Terraform plan only / Ansible --check --diff (no apply)')
    string(name: 'ENVIRONMENT', defaultValue: '', description: 'Name prefix + Terraform workspace (overrides tfvars when set)')
    string(name: 'OWNER', defaultValue: '', description: 'Owner tag (overrides tfvars when set)')
    string(name: 'AWS_REGION', defaultValue: '', description: 'AWS region override (e.g. ap-southeast-1)')
    string(name: 'AMI_ID', defaultValue: '', description: 'AMI override for all instance groups (empty = use tfvars)')
    string(name: 'CLDR_MNGR_COUNT', defaultValue: '', description: 'CM host count override')
    string(name: 'CLDR_MNGR_INSTANCE_TYPE', defaultValue: '', description: 'CM instance type override (e.g. m5.4xlarge)')
    string(name: 'CLDR_MNGR_VOLUME_SIZE', defaultValue: '', description: 'CM root volume GB override')
    string(name: 'IPA_SERVER_COUNT', defaultValue: '', description: 'FreeIPA server count override')
    string(name: 'IPA_SERVER_INSTANCE_TYPE', defaultValue: '', description: 'FreeIPA instance type override')
    string(name: 'PVCBASE_MASTER_COUNT', defaultValue: '', description: 'CDH base master count override')
    string(name: 'PVCBASE_WORKER_COUNT', defaultValue: '', description: 'CDH base worker count override')
    string(name: 'PVCBASE_WORKER_INSTANCE_TYPE', defaultValue: '', description: 'CDH base worker instance type override')
    string(name: 'PVCECS_MASTER_COUNT', defaultValue: '', description: 'ECS master count override')
    string(name: 'PVCECS_WORKER_COUNT', defaultValue: '', description: 'ECS worker count override')
    string(name: 'PVCECS_WORKER_INSTANCE_TYPE', defaultValue: '', description: 'ECS worker instance type override')
    string(name: 'TFVARS_FILE', defaultValue: '', description: 'Config file path relative to repo root (empty = auto-detect)')
    string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Git branch to checkout')
    string(name: 'NOTIFICATION_EMAIL', defaultValue: '', description: 'Email recipient (defaults to BUILD_USER_EMAIL when empty)')
    booleanParam(name: 'REFRESH_JENKINSFILE', defaultValue: false, description: 'Reload Jenkinsfile parameter definitions and exit')
  }

  options {
    timeout(time: 8, unit: 'HOURS')
    timestamps()
    ansiColor('xterm')
    buildDiscarder(logRotator(numToKeepStr: '30'))
  }

  environment {
    LANG = 'C.UTF-8'
    REPO_ROOT = "${WORKSPACE}"
    LOG_DIR = "${WORKSPACE}/jenkins/artifacts"
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
    TFVARS_FILE = "${params.TFVARS_FILE?.trim() ?: ''}"
    DRY_RUN = "${params.DRY_RUN}"
    PIPELINE_ACTION = "${params.PIPELINE_ACTION}"
    BUILD_RESULT = 'IN_PROGRESS'
    MAIL_TO = "${params.NOTIFICATION_EMAIL?.trim() ?: env.BUILD_USER_EMAIL ?: ''}"
  }

  stages {
    stage('Build') {
      steps {
        script {
          def label = "#${BUILD_NUMBER} — ${params.PIPELINE_ACTION}"
          if (params.DRY_RUN) { label += ' (dry-run)' }
          currentBuild.displayName = label
        }
      }
    }

    stage('DRY RUN: Reload Jenkinsfile') {
      when { expression { return params.REFRESH_JENKINSFILE } }
      steps {
        script {
          currentBuild.result = 'ABORTED'
          error('DRY RUN COMPLETED — Jenkinsfile parameters reloaded.')
        }
      }
    }

    stage('Resolve Action') {
      steps {
        script {
          def cfg = resolvePipelineAction(params.PIPELINE_ACTION)
          env.RUN_TERRAFORM = cfg.runTerraform
          env.RUN_ANSIBLE = cfg.runAnsible
          env.DEPLOY_PHASE = cfg.deployPhase
          env.REQUIRE_INVENTORY = cfg.requireInventory
          env.VALIDATE_ANSIBLE_SYNTAX = cfg.validateAnsibleSyntax
          env.PIPELINE_MODE = cfg.legacyMode
          echo "Resolved: terraform=${cfg.runTerraform}, ansible=${cfg.runAnsible}, phase=${cfg.deployPhase}, label=${cfg.label}"
        }
      }
    }

    stage('Check Parameters') {
      steps {
        script {
          def RED_BOLD = "\u001B[1;31m"
          def RESET = "\u001B[0m"
          def fail = { msg -> error "${RED_BOLD}ERROR: ${msg}${RESET}" }

          def awsRegionRegex = /^(us|eu|ap|sa|ca|me|af|il|cn|us-gov)-[a-z]+-\d{1}$/
          if (params.AWS_REGION?.trim() && !params.AWS_REGION.trim().matches(awsRegionRegex)) {
            fail("AWS_REGION '${params.AWS_REGION}' is not a valid AWS region format.")
          }

          def countParams = [
            'CLDR_MNGR_COUNT', 'CLDR_MNGR_VOLUME_SIZE',
            'IPA_SERVER_COUNT', 'PVCBASE_MASTER_COUNT', 'PVCBASE_WORKER_COUNT',
            'PVCECS_MASTER_COUNT', 'PVCECS_WORKER_COUNT'
          ]
          countParams.each { name ->
            def val = params."${name}"?.trim()
            if (val && !val.isInteger()) {
              fail("${name} must be a positive integer when set (got '${val}').")
            }
            if (val && val.toInteger() < 0) {
              fail("${name} cannot be negative.")
            }
          }

          if (env.REQUIRE_INVENTORY == 'true') {
            echo "INFO: ${params.PIPELINE_ACTION} requires ansible-playbooks/inventory.ini (from a prior terraform-only or full run)."
          }
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
      }
    }

    stage('Validate Prerequisites') {
      steps {
        sh '''
          set -euo pipefail
          mkdir -p "${LOG_DIR}"
          export VALIDATE_ANSIBLE_SYNTAX="${VALIDATE_ANSIBLE_SYNTAX:-true}"
          export REQUIRE_INVENTORY="${REQUIRE_INVENTORY:-false}"
          ./jenkins/scripts/validate-prereqs.sh
        '''
      }
    }

    stage('Terraform — Provision EC2') {
      when { expression { return env.RUN_TERRAFORM == 'true' } }
      steps {
        sh '''
          set -euo pipefail
          ./jenkins/scripts/run-terraform.sh
        '''
      }
    }

    stage('Ansible Deploy') {
      when { expression { return env.RUN_ANSIBLE == 'true' } }
      steps {
        sh '''
          set -euo pipefail
          export REQUIRE_INVENTORY=true
          ./jenkins/scripts/run-ansible.sh
        '''
      }
    }

    stage('Build Summary') {
      steps {
        script {
          sh """
            set -euo pipefail
            export BUILD_RESULT='${currentBuild.currentResult ?: 'SUCCESS'}'
            export PIPELINE_ACTION='${params.PIPELINE_ACTION}'
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
          set -euo pipefail
          export BUILD_RESULT=SUCCESS
          export PIPELINE_ACTION="${PIPELINE_ACTION}"
          ./jenkins/scripts/collect-artifacts.sh || true
          ./jenkins/scripts/build-summary.sh || true
        '''
        archivePipelineArtifacts()
        sendPipelineEmail(true)
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
          set -euo pipefail
          export BUILD_RESULT=FAILURE
          export ERROR_MESSAGE="${ERROR_MESSAGE:-Pipeline failed}"
          export PIPELINE_ACTION="${PIPELINE_ACTION}"
          ./jenkins/scripts/collect-artifacts.sh || true
          ./jenkins/scripts/build-summary.sh || true
        '''
        archivePipelineArtifacts()
        sendPipelineEmail(false)
      }
    }

    unstable {
      script {
        env.BUILD_RESULT = 'UNSTABLE'
        archivePipelineArtifacts()
        sendPipelineEmail(false)
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

def resolvePipelineAction(String action) {
  def ansiblePhases = [
    'prereqs-only'   : [phase: '1',   label: 'Prerequisites (phase 1)'],
    'identity-only'  : [phase: '2',   label: 'Identity / DNS (phase 2)'],
    'cm-install'     : [phase: '3',   label: 'Cloudera Manager install (phase 3)'],
    'cdh-base'       : [phase: '4',   label: 'CDH base cluster (phase 4)'],
    'ecs-install'    : [phase: '5',   label: 'ECS Data Services (phase 5)'],
    'ansible-all'    : [phase: 'all', label: 'Full Ansible flow'],
  ]

  switch (action) {
    case 'validate':
      return [runTerraform: 'false', runAnsible: 'false', deployPhase: 'n/a',
              requireInventory: 'false', validateAnsibleSyntax: 'true',
              legacyMode: 'validate', label: 'Validation only']
    case 'terraform-only':
      return [runTerraform: 'true', runAnsible: 'false', deployPhase: 'n/a',
              requireInventory: 'false', validateAnsibleSyntax: 'false',
              legacyMode: 'terraform', label: 'Terraform only (EC2 + inventory)']
    case 'full':
      return [runTerraform: 'true', runAnsible: 'true', deployPhase: 'all',
              requireInventory: 'false', validateAnsibleSyntax: 'true',
              legacyMode: 'full', label: 'Terraform + full Ansible']
    default:
      if (ansiblePhases.containsKey(action)) {
        def p = ansiblePhases[action]
        return [runTerraform: 'false', runAnsible: 'true', deployPhase: p.phase,
                requireInventory: 'true', validateAnsibleSyntax: 'true',
                legacyMode: 'ansible', label: p.label]
      }
      error("Unknown PIPELINE_ACTION: ${action}")
  }
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
    'ansible-playbooks/inventory.ini'
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
  def phaseInfo = env.DEPLOY_PHASE ?: 'n/a'

  def attachmentList = []
  ['build-summary.txt', "terraform-${env.BUILD_NUMBER}.log", "ansible-${env.BUILD_NUMBER}.log",
   'inventory.ini', 'error-summary.txt'].each { name ->
    if (fileExists("${env.WORKSPACE}/jenkins/artifacts/${name}")) {
      attachmentList << "jenkins/artifacts/${name}"
    }
  }
  fileExists("${env.WORKSPACE}/ansible-playbooks/inventory.ini") && attachmentList << 'ansible-playbooks/inventory.ini'

  emailext(
    to: env.MAIL_TO,
    subject: "${statusIcon} Jenkins ${statusText}: ${env.JOB_NAME} [${env.BUILD_NUMBER}] — ${params.PIPELINE_ACTION}",
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
      <tr><th style="text-align:left;padding:8px;border:1px solid #ddd;background:#f2f2f2;">Action</th><td style="padding:8px;border:1px solid #ddd;">${params.PIPELINE_ACTION} (phase ${phaseInfo}, dry-run=${params.DRY_RUN})</td></tr>
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
