// the first version is used to build the binary that gets shipped to Docker Hub.
local go_versions = ['1.16', '1.15.8'];

local test_ci_dockerfile = {
  name: 'test-ci-dockerfile',
  image: 'plugins/docker',
  settings: {
    repo: 'videodev/video-transcoding-api',
    dockerfile: 'drone/Dockerfile',
    dry_run: true,
  },
  when: {
    event: ['pull_request'],
  },
  depends_on: ['build'],
};

local push_to_dockerhub = {
  name: 'build-and-push-to-dockerhub',
  image: 'plugins/docker',
  settings: {
    repo: 'videodev/video-transcoding-api',
    auto_tag: true,
    dockerfile: 'drone/Dockerfile',
    username: { from_secret: 'docker_username' },
    password: { from_secret: 'docker_password' },
  },
  when: {
    ref: [
      'refs/tags/*',
      'refs/heads/master',
    ],
  },
  depends_on: ['coverage', 'lint', 'build'],
};

local goreleaser = {
  name: 'goreleaser',
  image: 'goreleaser/goreleaser',
  commands: [
    'git fetch --tags',
    'goreleaser release',
  ],
  environment: {
    GITHUB_TOKEN: {
      from_secret: 'github_token',
    },
  },
  depends_on: ['coverage', 'lint'],
  when: {
    event: ['tag'],
  },
};

local release_steps = [
  test_ci_dockerfile,
  push_to_dockerhub,
  goreleaser,
];

local mod_download(go_version) = {
  name: 'mod-download',
  image: 'golang:%(go_version)s' % { go_version: go_version },
  commands: ['go mod download'],
  depends_on: ['clone'],
};

// TODO(fsouza): run redis as a service in Drone. This actually requires a
// change to our test suite, because it requires Redis to be running on
// localhost and that's not how Drone works.
local coverage(go_version) = {
  name: 'coverage',
  image: 'golang:%(go_version)s' % { go_version: go_version },
  commands: [
    'apt update',
    'apt install -y redis-server',
    'redis-server &>/dev/null &',
    'timeout 10 sh -c "while ! redis-cli ping; do echo waiting for redis-server to start; sleep 1; done"',
    'make gocoverage',
  ],
  depends_on: ['mod-download'],
};

local lint = {
  name: 'lint',
  image: 'golangci/golangci-lint:v1.25.0',
  commands: ['make runlint'],
  depends_on: ['mod-download'],
};

local build(go_version) = {
  name: 'build',
  image: 'golang:%(go_version)s' % { go_version: go_version },
  commands: ['make build'],
  environment: { CGO_ENABLED: '0' },
  depends_on: ['mod-download'],
  when: {
    event: ['pull_request', 'push', 'tag'],
  },
};

local pipeline(go_version) = {
  kind: 'pipeline',
  name: 'go-%(go_version)s' % { go_version: go_version },
  workspace: {
    base: '/go',
    path: 'video-transcoding-api',
  },
  steps: [
    mod_download(go_version),
    coverage(go_version),
    lint,
    build(go_version),
  ] + if go_version == go_versions[0] then release_steps else [],
};

std.map(pipeline, go_versions)
