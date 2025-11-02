import React from 'npm:react@18.2.0';
import { Button, Heading, Section, Text } from 'npm:@react-email/components@0.0.22';
import { BaseLayout } from './BaseLayout.tsx';
import { emailTheme } from '../theme.ts';

interface WelcomeEmailProps {
  readonly name?: string;
  readonly downloadLink: string;
  readonly unsubscribeUrl: string;
}

export const WelcomeEmail: React.FC<WelcomeEmailProps> = ({ name, downloadLink, unsubscribeUrl }) => {
  const firstName = name?.split(' ')[0] || 'Stellr Lover';
  return (
    <BaseLayout
      previewText={`Hey ${firstName}, welcome to Stellr!`}
      headline="Welcome to Stellr"
      unsubscribeUrl={unsubscribeUrl}
    >
      <Heading className={emailTheme.heading}>Welcome in, {firstName} ✨</Heading>
      <Section className="space-y-5">
        <Text className={emailTheme.bodyText}>
          You just joined the dating app built for intentional connections, astrology-first insights, and real safety.
        </Text>
        <Text className={emailTheme.bodyText}>Here’s how to get the most out of Stellr:</Text>
        <ul className={emailTheme.list}>
          <li>Complete your cosmic profile for curated match signals.</li>
          <li>Use in-app prompts to spark conversation with your compatible matches.</li>
          <li>Check the Compatibility Dashboard for weekly astro updates.</li>
        </ul>
      </Section>
      <Section className="text-center">
        <Button href={downloadLink} className={emailTheme.primaryButton}>
          Jump back into Stellr
        </Button>
      </Section>
    </BaseLayout>
  );
};
