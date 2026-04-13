name: Build and Push Container Image

permissions:
  id-token: write
  contents: read

on:
  push:
    branches:
      - stg
      - abc
      - prd
  workflow_dispatch:

env:
  AWS_REGION: ap-northeast-1
  JAVA_VERSION: 17

jobs:
  build-and-push:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up JDK
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: ${{ env.JAVA_VERSION }}

      - name: Cache Gradle
        uses: actions/cache@v4
        with:
          path: |
            ~/.gradle/caches
            ~/.gradle/wrapper
          key: ${{ runner.os }}-gradle-${{ hashFiles('**/*.gradle*', '**/gradle-wrapper.properties') }}
          restore-keys: |
            ${{ runner.os }}-gradle-

      - name: Build with Gradle
        run: |
          chmod +x ./gradlew
          ./gradlew --no-daemon clean bootJar -x test

      - name: Prepare Docker artifact
        shell: bash
        run: |
          APP_JAR="$(find build/libs -maxdepth 1 -type f -name '*.jar' ! -name '*-plain.jar' | head -n 1)"

          if [ -z "$APP_JAR" ]; then
            echo "No executable jar found in build/libs"
            ls -la build/libs || true
            exit 1
          fi

          cp "$APP_JAR" build/libs/app.jar
          ls -la build/libs/

      - name: Set deployment variables
        id: vars
        shell: bash
        env:
          ECR_REPOSITORY_STG: ${{ vars.ECR_REPOSITORY_STG }}
          ECR_REPOSITORY_ABC: ${{ vars.ECR_REPOSITORY_ABC }}
          ECR_REPOSITORY_PRD: ${{ vars.ECR_REPOSITORY_PRD }}
          AWS_ROLE_ARN_SHARED: ${{ secrets.AWS_ROLE_ARN_SHARED }}
          AWS_ROLE_ARN_PRD: ${{ secrets.AWS_ROLE_ARN_PRD }}
        run: |
          case "${GITHUB_REF_NAME}" in
            stg)
              echo "ecr_repository=${ECR_REPOSITORY_STG}" >> "$GITHUB_OUTPUT"
              echo "image_tag=stg" >> "$GITHUB_OUTPUT"
              echo "role_to_assume=${AWS_ROLE_ARN_SHARED}" >> "$GITHUB_OUTPUT"
              ;;
            abc)
              echo "ecr_repository=${ECR_REPOSITORY_ABC}" >> "$GITHUB_OUTPUT"
              echo "image_tag=abc" >> "$GITHUB_OUTPUT"
              echo "role_to_assume=${AWS_ROLE_ARN_SHARED}" >> "$GITHUB_OUTPUT"
              ;;
            prd)
              echo "ecr_repository=${ECR_REPOSITORY_PRD}" >> "$GITHUB_OUTPUT"
              echo "image_tag=prd" >> "$GITHUB_OUTPUT"
              echo "role_to_assume=${AWS_ROLE_ARN_PRD}" >> "$GITHUB_OUTPUT"
              ;;
            *)
              echo "Unsupported branch: ${GITHUB_REF_NAME}"
              exit 1
              ;;
          esac

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ${{ env.AWS_REGION }}
          role-to-assume: ${{ steps.vars.outputs.role_to_assume }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: ${{ steps.vars.outputs.ecr_repository }}
          IMAGE_TAG: ${{ steps.vars.outputs.image_tag }}
        run: |
          docker build \
            --build-arg JAVA_VERSION=${{ env.JAVA_VERSION }} \
            -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG

      - name: Show pushed image
        env:
          REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          REPOSITORY: ${{ steps.vars.outputs.ecr_repository }}
          IMAGE_TAG: ${{ steps.vars.outputs.image_tag }}
        run: |
          echo "Pushed image: $REGISTRY/$REPOSITORY:$IMAGE_TAG"