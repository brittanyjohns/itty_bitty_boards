module.exports = {
  theme: {
    extend: {
      height: {
        '128': '32rem',
      }
    }
  },
  plugins: [
    require('flowbite/plugin')
],
  content: [
    './app/views/**/*.html.erb',
    './app/helpers/**/*.rb',
    './app/assets/stylesheets/**/*.css',
    './app/javascript/**/*.js',
    "./node_modules/flowbite/**/*.js"
  ]
}
