pipeline {
    agent any
    tools {
        // Install the Maven version configured as "M3" and add it to the path.
        maven "MAVEN3"
    }
    stages {
        stage('Hello') {
            steps {
                echo 'Hello World'
            }
        }
        stage('Checkout') {
            steps {
                echo 'Checkout started...'
                git 'https://github.com/developers8085/maven-app.git'
            }
            
        }
        stage('Build') {
            steps {
                echo 'Build started...'
                sh "mvn --version"
                sh "mvn install"
                sh "mvn package"
            }
            
        }
        stage('Test') {
            steps {
                echo 'Test started...'
            }
            
        }
    }
}
