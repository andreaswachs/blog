module.exports = {
  branches: ['main'],
  plugins: [
    '@semantic-release/commit-analyzer',
    '@semantic-release/release-notes-generator',
    [
      '@semantic-release/exec',
      {
        publishCmd: 'echo "Version ${nextRelease.version} (${nextRelease.type})"',
      },
    ],
  ],
};
