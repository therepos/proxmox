import { themes as prismThemes } from 'prism-react-renderer';

const currentYear = new Date().getFullYear();
const org = process.env.ORG_NAME;
const repo = process.env.PROJECT_NAME;
const footer = require('./footer');

export default {
  title: process.env.SITE_TITLE,
  tagline: 'Proxmox',
  url: process.env.SITE_URL,
  baseUrl: process.env.BASE_URL,
  organizationName: process.env.ORG_NAME,
  projectName: process.env.PROJECT_NAME,
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
          editUrl: 'https://github.com/${org}/${repo}/edit/main/',
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
          href: 'https://github.com/${org}/${repo}',
          position: 'right',
          className: 'header-github-link',
          'aria-label': 'GitHub repository',
        },
      ],
    },
    docs: {
      sidebar: {
        hideable: true,
        autoCollapseCategories: true,
      },
    },
    prism: {
      theme: prismThemes.github,
      additionalLanguages: ['git'],
    },
    footer: footer,
  },
};
