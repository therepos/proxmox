import { themes as prismThemes } from 'prism-react-renderer';

const currentYear = new Date().getFullYear();

export default {
  title: 'Proxmox',
  tagline: 'Proxmox',
  url: 'https://therepos.github.io',
  baseUrl: '/proxmox/',
  organizationName: 'therepos',
  projectName: 'proxmox',
  deploymentBranch: 'gh-pages',
  trailingSlash: false,

  presets: [
    [
      '@docusaurus/preset-classic',
      {
        docs: {
          path: 'docs',
          routeBasePath: '/',
          sidebarPath: './sidebars.js',
          showLastUpdateTime: true,
          sidebarCollapsible: true,
          editUrl: 'https://github.com/therepos/proxmox/edit/main/',
        },
        theme: {
          customCss: './src/css/styles.css',
        },
      },
    ],
  ],

  themeConfig: {
    navbar: {
      title: 'Proxmox',
      items: [
        {
          type: 'search',
          position: 'right',
        },
        {
          href: 'https://github.com/therepos/proxmox',
          position: 'right',
          className: 'header-github-link',
          'aria-label': 'GitHub repository',
        },
      ],
    },
    prism: {
      theme: prismThemes.github,
      additionalLanguages: ['git'],
    },
    footer: {
      style: 'dark',
      links: [],
      copyright: `
        <div class="footer-row">
          <div class="footer-left">
            <a href="https://creativecommons.org/licenses/by/4.0/" target="_blank" style="color: #ebedf0;">CC BY 4.0</a> © ${currentYear} therepos.<br/>
            Made with Docusaurus.
          </div>
          <div class="footer-icons">
            <a href="https://github.com" class="icon icon-github" target="_blank" aria-label="GitHub"></a>
            <a href="https://hub.docker.com" class="icon icon-docker" target="_blank" aria-label="Docker"></a>
          </div>
        </div>
      `,
    },
  },
};
