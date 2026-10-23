실습 코드는 공개 저장소 https://github.com/sandcorporation/infralab-labs 의 `labs/node-api`·`labs/python-api`·`labs/java-api` 폴더에 있고 태그 `v1` 부터 쓰며, 고치면 태그를 올리고 시나리오 YAML 의 태그도 함께 올린다.
의도된 실패: node-api 는 테스트 2건, java-api 는 1건이 의도적으로 실패하고 python-api 는 통과한다 (태그 v2 부터 gradlew.bat 은 CRLF, java toolchain 25).
