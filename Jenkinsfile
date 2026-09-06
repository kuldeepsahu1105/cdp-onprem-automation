pipeline {
  agent any

  parameters {
    choice(
      name: 'PIPELINE_MODE',
      choices: ['validate', 'terraform', 'ansible', 'full'],
      description: 'validate = checks only; terraform = infra; ansible = CM/CDH/ECS deploy; full = terraform then ansible'
    )
    choice(
      name: 'DEPLOY_PHASE',
      choices: ['1', '2', '3', '4', '5', 'all'],
      description: 'Ansible phase: 1=prereqs, 2=identity, 3=CM, 4=CDH base, 5=ECS, all=full flow'
    )
    booleanParam(name: 'DRY_RUN', defaultValue: false, description: 'Terraform plan only / Ansible --check --diff (no apply)')
    string(name: 'ENVIRONMENT', defaultValue: '', description: 'Optional override for tfvars ENVIRONMENT (Terraform workspace / name prefix)')
    string(name: 'OWNER', defaultValue: '', description: 'Optional override for tfvars OWNER tag (required if not set in tfvars)')
    string(name: 'AWS_REGION', defaultValue: '', description: 'Optional override for tfvars AWS_REGION (e.g. ap-southeast-1)')
    string(name: 'TFVARS_FILE', defaultValue: '', description: 'Config file path relative to repo root (empty = auto-detect .tfvars.yaml / .tfvars.env)')
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
    TFVARS_FILE = "${params.TFVARS_FILE?.trim() ?: ''}"
    DEPLOY_PHASE = "${params.DEPLOY_PHASE}"
    DRY_RUN = "${params.DRY_RUN}"
    PIPELINE_MODE = "${params.PIPELINE_MODE}"
    BUILD_RESULT = 'IN_PROGRESS'
    RUN_TERRAFORM = "${params.PIPELINE_MODE in ['terraform', 'full'] ? 'true' : 'false'}"
    RUN_ANSIBLE = "${params.PIPELINE_MODE in ['ansible', 'full'] ? 'true' : 'false'}"
    REQUIRE_INVENTORY = "${params.PIPELINE_MODE == 'ansible' ? 'true' : 'false'}"
    MAIL_TO = "${params.NOTIFICATION_EMAIL?.trim() ?: env.BUILD_USER_EMAIL ?: ''}"
  }

  stages {
    stage('Build') {
      steps {
        script {
          def label = "#${BUILD_NUMBER} — ${params.PIPELINE_MODE}"
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

          def validPhases = ['1', '2', '3', '4', '5', 'all']
          if (!validPhases.contains(params.DEPLOY_PHASE)) {
            fail("DEPLOY_PHASE must be one of: ${validPhases.join(', ')}")
          }

          if (params.PIPELINE_MODE in ['ansible', 'full'] && params.DEPLOY_PHASE == '1' && params.PIPELINE_MODE == 'ansible') {
            echo 'INFO: ansible-only mode with DEPLOY_PHASE=1 (prerequisites). Inventory must exist.'
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
          export VALIDATE_ANSIBLE_SYNTAX=true
          ./jenkins/scripts/validate-prereqs.sh
        '''
      }
    }

    stage('Terraform') {
      when { expression { return params.PIPELINE_MODE in ['terraform', 'full'] } }
      steps {
        sh '''
          set -euo pipefail
          ./jenkins/scripts/run-terraform.sh
        '''
      }
    }

    stage('Ansible Deploy') {
      when { expression { return params.PIPELINE_MODE in ['ansible', 'full'] } }
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
    subject: "${statusIcon} Jenkins ${statusText}: ${env.JOB_NAME} [${env.BUILD_NUMBER}] — ${params.PIPELINE_MODE}",
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
      <tr><th style="text-align:left;padding:8px;border:1px solid #ddd;background:#f2f2f2;">Mode</th><td style="padding:8px;border:1px solid #ddd;">${params.PIPELINE_MODE} (phase ${params.DEPLOY_PHASE}, dry-run=${params.DRY_RUN})</td></tr>
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
