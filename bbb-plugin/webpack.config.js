const path = require('path');

module.exports = {
  entry: './src/index.tsx',
  output: {
    filename: 'plugin.js',
    path: path.resolve(__dirname, 'dist'),
    library: {
      type: 'umd',
      name: 'LiveTranscriptPlugin',
    },
  },
  resolve: {
    extensions: ['.ts', '.tsx', '.js'],
  },
  module: {
    rules: [
      {
        test: /\.tsx?$/,
        use: 'ts-loader',
        exclude: /node_modules/,
      },
    ],
  },
  externals: {
    react: 'React',
    'react-dom': 'ReactDOM',
  },
};
