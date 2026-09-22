// Keep native details semantics; enhance only the opening and closing motion.
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
document.querySelectorAll('details').forEach(details => {
  const summary = details.querySelector('summary');
  let animation;
  let opening = details.open;
  summary.addEventListener('click', event => {
    event.preventDefault();
    opening = !(animation ? opening : details.open);
    const from = details.getBoundingClientRect().height;
    animation?.cancel();
    if (reducedMotion.matches || !details.animate) {
      animation = undefined;
      details.style.overflow = '';
      details.open = opening;
      return;
    }
    details.open = true;
    const style = getComputedStyle(details);
    const edges = ['paddingTop', 'paddingBottom', 'borderTopWidth', 'borderBottomWidth']
      .reduce((sum, name) => sum + parseFloat(style[name]), 0);
    const to = opening ? details.getBoundingClientRect().height
      : summary.getBoundingClientRect().height + edges;
    details.style.overflow = 'hidden';
    animation = details.animate({height: [`${from}px`, `${to}px`]}, {
      duration: 280, easing: 'cubic-bezier(.22, 1, .36, 1)'
    });
    animation.onfinish = () => {
      details.open = opening;
      details.style.overflow = '';
      animation = undefined;
    };
  });
});
