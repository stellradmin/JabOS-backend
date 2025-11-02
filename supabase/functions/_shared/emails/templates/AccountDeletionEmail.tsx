import React from 'npm:react@18.2.0';
import { Heading, Section, Text } from 'npm:@react-email/components@0.0.22';
import { BaseLayout } from './BaseLayout.tsx';
import { emailTheme } from '../theme.ts';

interface AccountDeletionProps {
  readonly name?: string;
  readonly unsubscribeUrl: string;
  readonly feedbackLink?: string;
}

export const AccountDeletionEmail: React.FC<AccountDeletionProps> = ({
  name,
  unsubscribeUrl,
  feedbackLink = 'https://stellr.app/feedback',
}) => {
  const firstName = name?.split(' ')[0] || 'Friend';
  return (
    <BaseLayout
      previewText={`Your Stellr account has been deleted, ${firstName}`}
      headline="Account deleted"
      unsubscribeUrl={unsubscribeUrl}
    >
      <Heading className={emailTheme.heading}>Stellr account closed</Heading>
      <Section className="space-y-4">
        <Text className={emailTheme.bodyText}>Your Stellr account is now deleted. We’re sorry to see you go.</Text>
        <Text className={emailTheme.bodyText}>
          If you changed your mind, you can always create a fresh profile. We’d also love feedback — it helps us build
          the experience you want.
        </Text>
        <Text className={emailTheme.bodyText}>
          Share feedback: <a href={feedbackLink} className={emailTheme.footerLink}>{feedbackLink}</a>
        </Text>
      </Section>
    </BaseLayout>
  );
};
