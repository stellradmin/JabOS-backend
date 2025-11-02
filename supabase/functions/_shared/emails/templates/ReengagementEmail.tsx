import React from 'npm:react@18.2.0';
import { Button, Heading, Section, Text } from 'npm:@react-email/components@0.0.22';
import { BaseLayout } from './BaseLayout.tsx';
import { emailTheme } from '../theme.ts';

interface ReengagementEmailProps {
  readonly name?: string;
  readonly cadence: 'day1' | 'day3' | 'day7' | 'day14' | 'day30';
  readonly highlight: string;
  readonly downloadLink: string;
  readonly unsubscribeUrl: string;
  readonly incentive?: string;
}

const cadenceCopy: Record<ReengagementEmailProps['cadence'], { title: string; cta: string }> = {
  day1: { title: 'See who shares your cosmic energy', cta: 'Meet your cosmic matches' },
  day3: { title: 'Your perfect match might be waiting', cta: 'Open Stellr to explore' },
  day7: { title: 'Your matches miss you', cta: 'See who wants to connect' },
  day14: { title: 'Cosmic connections waiting', cta: 'Claim your compatibility' },
  day30: { title: 'Last chance to keep your orbit', cta: 'Rejoin Stellr today' },
};

export const ReengagementEmail: React.FC<ReengagementEmailProps> = ({
  name,
  cadence,
  highlight,
  downloadLink,
  unsubscribeUrl,
  incentive,
}) => {
  const firstName = name?.split(' ')[0] || 'Friend';
  const copy = cadenceCopy[cadence];
  return (
    <BaseLayout
      previewText={`${firstName}, ${copy.title.toLowerCase()}`}
      headline="We saved your cosmic profile"
      unsubscribeUrl={unsubscribeUrl}
    >
      <Heading className={emailTheme.heading}>{copy.title}</Heading>
      <Section className="space-y-4">
        <Text className={emailTheme.bodyText}>{highlight}</Text>
        {incentive && (
          <Text className={emailTheme.mutedText}>Exclusive perk: {incentive}</Text>
        )}
        <Button href={downloadLink} className={emailTheme.primaryButton}>
          {copy.cta}
        </Button>
      </Section>
    </BaseLayout>
  );
};
