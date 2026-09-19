pipeline {
    agent {
        node {
            label 'linux-build'
        }
    }

    environment {
        APP_NAME = 'taskflow-api'
        NODE_ENV = 'test'
    }

    options {
        // A hung npm install or test run must not hold the executor forever
        timeout(time: 10, unit: 'MINUTES')
    }

    stages {
        stage('Install') {
            steps {
                dir('server') {
                    echo "=== Installing Dependencies for ${APP_NAME} (${NODE_ENV}) ==="
                    sh 'npm install --package-lock-only --legacy-peer-deps --no-audit'
                    sh 'npm ci --legacy-peer-deps'
                }
            }
        }

        stage('Lint') {
            steps {
                dir('server') {
                    echo "=== Running Linter for ${APP_NAME} ==="
                    sh 'npm run lint || true'
                }
            }
        }

        stage('Unit Test') {
            steps {
                dir('server') {
                    echo "=== Running Unit Tests ==="
                    sh 'npm test'
                }
            }
        }
                stage('Deploy — Staging') {
            when {
                branch 'develop'
            }
            steps {
                echo '=== Deploying to Staging Server ==='
                sh 'echo deploying to staging...'
            }
        }

        stage('Deploy — Production') {
            when {
                branch 'main'
            }
            input {
                message 'Deploy to production?'
            }
            steps {
                echo '=== Deploying to Production Server ==='
                sh 'echo deploying to production...'
            }
        }

    }

    post {
        success {
            echo "✅ ${env.APP_NAME} passed on ${env.NODE_ENV}"
        }
        failure {
            echo "❌ Failed at stage: ${env.STAGE_NAME}"
        }
        always {
            archiveArtifacts artifacts: 'npm-debug.log*', allowEmptyArchive: true
        }
    }
}
